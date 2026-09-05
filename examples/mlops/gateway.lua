local gateway = require "examples.mlops.gateway_app"
local http = require "akkar.http"
local app = gateway.new {
  service = assert(os.getenv "ML_SERVICE_URL", "ML_SERVICE_URL is required"),
  token = assert(os.getenv "ML_INTERNAL_TOKEN", "ML_INTERNAL_TOKEN is required"),
  model_name = os.getenv "ML_MODEL_NAME" or "akkar-reference",
  credentials = gateway.credentials(assert(os.getenv "ML_CLIENT_KEYS_FILE",
                                            "ML_CLIENT_KEYS_FILE is required")),
}
app:run {
  host = os.getenv "HOST" or "127.0.0.1",
  port = tonumber(os.getenv "PORT") or 8080,
  http = http.connect {
    timeout = 10, max_body = 8 * 1024 * 1024, retries = 1, pool_size = 16,
    breaker = { threshold = 5, cooldown = 10 },
  },
  body_limit = 1024 * 1024, header_limit = 32 * 1024, header_count_limit = 100,
  json_depth_limit = 64, max_concurrent = 512, timeout = 15,
  read_timeout = 15, write_timeout = 15,
}
