package deviceclaim

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/cedar2025/xboard-node/internal/config"
	"github.com/cedar2025/xboard-node/internal/kernel"
)

const claimScript = `
local userKey = KEYS[1]
local deviceKey = KEYS[2]
local deviceID = ARGV[1]
local owner = ARGV[2]
local limit = tonumber(ARGV[3])
local ttl = tonumber(ARGV[4])

if limit <= 0 then
  return {1, owner}
end

if redis.call('EXISTS', deviceKey) == 1 then
  redis.call('SADD', deviceKey, owner)
  redis.call('EXPIRE', deviceKey, ttl)
  redis.call('SADD', userKey, deviceID)
  redis.call('EXPIRE', userKey, ttl)
  return {1, owner}
end

local base = string.sub(userKey, 1, string.len(userKey) - string.len(':devices'))
local devices = redis.call('SMEMBERS', userKey)
for _, staleDeviceID in ipairs(devices) do
  local staleDeviceKey = base .. ':device:' .. staleDeviceID .. ':owners'
  if redis.call('EXISTS', staleDeviceKey) == 0 then
    redis.call('SREM', userKey, staleDeviceID)
  end
end

local count = redis.call('SCARD', userKey)
if count < limit then
  redis.call('SADD', userKey, deviceID)
  redis.call('EXPIRE', userKey, ttl)
  redis.call('SADD', deviceKey, owner)
  redis.call('EXPIRE', deviceKey, ttl)
  return {1, owner}
end

return {0, ''}
`

const releaseScript = `
local userKey = KEYS[1]
local deviceKey = KEYS[2]
local deviceID = ARGV[1]
local owner = ARGV[2]

if redis.call('EXISTS', deviceKey) == 0 then
  return 1
end

redis.call('SREM', deviceKey, owner)
if redis.call('SCARD', deviceKey) == 0 then
  redis.call('DEL', deviceKey)
  redis.call('SREM', userKey, deviceID)
end
return 1
`

const refreshScript = `
local userKey = KEYS[1]
local deviceKey = KEYS[2]
local deviceID = ARGV[1]
local owner = ARGV[2]
local ttl = tonumber(ARGV[3])

if redis.call('SISMEMBER', deviceKey, owner) == 1 then
  redis.call('EXPIRE', deviceKey, ttl)
  redis.call('SADD', userKey, deviceID)
  redis.call('EXPIRE', userKey, ttl)
  return 1
end
return 0
`

// RedisStore implements kernel.DeviceClaimStore using Redis Lua scripts. Every
// CLAIM/RELEASE operation is a single EVAL, so all nodes that point at the same
// Redis instance share one atomic admission source.
type RedisStore struct {
	addr     string
	password string
	db       int
	prefix   string
	ttl      time.Duration
	dialer   net.Dialer
}

func NewRedisStore(cfg config.DeviceClaimConfig) (*RedisStore, error) {
	if cfg.Type != "" && cfg.Type != "redis" {
		return nil, fmt.Errorf("unsupported device_claim type %q", cfg.Type)
	}
	addr := strings.TrimSpace(cfg.Addr)
	if addr == "" {
		addr = "127.0.0.1:6379"
	}
	prefix := strings.TrimSpace(cfg.Prefix)
	if prefix == "" {
		prefix = "xboard:device-claim"
	}
	ttl := cfg.TTL
	if ttl <= 0 {
		ttl = 300
	} else if ttl < 90 {
		// ConnTracker refreshes claims every 30s. Keep Redis TTL comfortably
		// above that so transient scheduler/network delays do not let a healthy
		// long-lived connection expire and admit a second device.
		ttl = 90
	}
	return &RedisStore{addr: addr, password: cfg.Password, db: cfg.DB, prefix: prefix, ttl: time.Duration(ttl) * time.Second}, nil
}

func (s *RedisStore) Claim(ctx context.Context, userUUID, deviceID, ownerToken string, limit int) (kernel.DeviceClaim, error) {
	if limit <= 0 {
		return kernel.DeviceClaim{Allowed: true, OwnerToken: ownerToken}, nil
	}
	v, err := s.eval(ctx, claimScript, []string{s.userKey(userUUID), s.deviceKey(userUUID, deviceID)}, deviceID, ownerToken, strconv.Itoa(limit), strconv.Itoa(int(s.ttl.Seconds())))
	if err != nil {
		return kernel.DeviceClaim{}, err
	}
	arr, ok := v.([]any)
	if !ok || len(arr) < 1 {
		return kernel.DeviceClaim{}, fmt.Errorf("unexpected claim response: %#v", v)
	}
	allowed, _ := redisInt(arr[0])
	claim := kernel.DeviceClaim{Allowed: allowed == 1, OwnerToken: ownerToken}
	if len(arr) > 1 {
		if tok, ok := arr[1].(string); ok && tok != "" {
			claim.OwnerToken = tok
		}
	}
	return claim, nil
}

func (s *RedisStore) Release(ctx context.Context, userUUID, deviceID, ownerToken string) error {
	_, err := s.eval(ctx, releaseScript, []string{s.userKey(userUUID), s.deviceKey(userUUID, deviceID)}, deviceID, ownerToken)
	return err
}

func (s *RedisStore) Refresh(ctx context.Context, userUUID, deviceID, ownerToken string) error {
	_, err := s.eval(ctx, refreshScript, []string{s.userKey(userUUID), s.deviceKey(userUUID, deviceID)}, deviceID, ownerToken, strconv.Itoa(int(s.ttl.Seconds())))
	return err
}

func (s *RedisStore) userKey(userUUID string) string {
	return s.prefix + ":user:" + userUUID + ":devices"
}

func (s *RedisStore) deviceKey(userUUID, deviceID string) string {
	return s.prefix + ":user:" + userUUID + ":device:" + deviceID + ":owners"
}

func (s *RedisStore) eval(ctx context.Context, script string, keys []string, args ...string) (any, error) {
	cmd := []string{"EVAL", script, strconv.Itoa(len(keys))}
	cmd = append(cmd, keys...)
	cmd = append(cmd, args...)
	return s.do(ctx, cmd...)
}

func (s *RedisStore) do(ctx context.Context, args ...string) (any, error) {
	conn, err := s.dialer.DialContext(ctx, "tcp", s.addr)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	} else {
		_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	}

	r := bufio.NewReader(conn)
	if s.password != "" {
		if err := writeArray(conn, "AUTH", s.password); err != nil {
			return nil, err
		}
		if _, err := readRESP(r); err != nil {
			return nil, err
		}
	}
	if s.db != 0 {
		if err := writeArray(conn, "SELECT", strconv.Itoa(s.db)); err != nil {
			return nil, err
		}
		if _, err := readRESP(r); err != nil {
			return nil, err
		}
	}
	if err := writeArray(conn, args...); err != nil {
		return nil, err
	}
	return readRESP(r)
}

func writeArray(w io.Writer, args ...string) error {
	if _, err := fmt.Fprintf(w, "*%d\r\n", len(args)); err != nil {
		return err
	}
	for _, arg := range args {
		if _, err := fmt.Fprintf(w, "$%d\r\n%s\r\n", len(arg), arg); err != nil {
			return err
		}
	}
	return nil
}

func readRESP(r *bufio.Reader) (any, error) {
	b, err := r.ReadByte()
	if err != nil {
		return nil, err
	}
	switch b {
	case '+':
		return readLine(r)
	case '-':
		line, _ := readLine(r)
		return nil, errors.New(line)
	case ':':
		line, err := readLine(r)
		if err != nil {
			return nil, err
		}
		return strconv.ParseInt(line, 10, 64)
	case '$':
		line, err := readLine(r)
		if err != nil {
			return nil, err
		}
		n, err := strconv.Atoi(line)
		if err != nil {
			return nil, err
		}
		if n < 0 {
			return "", nil
		}
		buf := make([]byte, n+2)
		if _, err := io.ReadFull(r, buf); err != nil {
			return nil, err
		}
		return string(buf[:n]), nil
	case '*':
		line, err := readLine(r)
		if err != nil {
			return nil, err
		}
		n, err := strconv.Atoi(line)
		if err != nil {
			return nil, err
		}
		if n < 0 {
			return []any(nil), nil
		}
		arr := make([]any, n)
		for i := 0; i < n; i++ {
			arr[i], err = readRESP(r)
			if err != nil {
				return nil, err
			}
		}
		return arr, nil
	default:
		return nil, fmt.Errorf("unexpected redis response byte %q", b)
	}
}

func readLine(r *bufio.Reader) (string, error) {
	line, err := r.ReadString('\n')
	if err != nil {
		return "", err
	}
	return strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r"), nil
}

func redisInt(v any) (int64, bool) {
	switch n := v.(type) {
	case int64:
		return n, true
	case string:
		i, err := strconv.ParseInt(n, 10, 64)
		return i, err == nil
	default:
		return 0, false
	}
}
