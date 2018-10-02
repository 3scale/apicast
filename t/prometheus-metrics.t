use lib 't';
use Test::APIcast::Blackbox 'no_plan';

# The output varies between requests, so run only once
repeat_each(1);

run_tests();

__DATA__

=== TEST 1: metrics endpoint works
--- configuration
{
}
--- request
GET /metrics
--- more_headers
Host: metrics
--- response_body
# HELP apicast_http_connections Number of HTTP connections
# TYPE apicast_http_connections gauge
apicast_http_connections{state="accepted"} 1
apicast_http_connections{state="active"} 1
apicast_http_connections{state="handled"} 1
apicast_http_connections{state="reading"} 0
apicast_http_connections{state="total"} 1
apicast_http_connections{state="waiting"} 0
apicast_http_connections{state="writing"} 1
# HELP apicast_nginx_metric_errors_total Number of nginx-lua-prometheus errors
# TYPE apicast_nginx_metric_errors_total counter
apicast_nginx_metric_errors_total 0
# HELP apicast_shdict_capacity OpenResty shared dictionary capacity
# TYPE apicast_shdict_capacity gauge
apicast_shdict_capacity{dict="api_keys"} 10485760
apicast_shdict_capacity{dict="batched_reports"} 1048576
apicast_shdict_capacity{dict="batched_reports_locks"} 1048576
apicast_shdict_capacity{dict="cached_auths"} 1048576
apicast_shdict_capacity{dict="configuration"} 10485760
apicast_shdict_capacity{dict="init"} 16384
apicast_shdict_capacity{dict="limiter"} 1048576
apicast_shdict_capacity{dict="locks"} 1048576
apicast_shdict_capacity{dict="prometheus_metrics"} 16777216
# HELP apicast_shdict_free_space OpenResty shared dictionary free space
# TYPE apicast_shdict_free_space gauge
apicast_shdict_free_space{dict="api_keys"} 10412032
apicast_shdict_free_space{dict="batched_reports"} 1032192
apicast_shdict_free_space{dict="batched_reports_locks"} 1032192
apicast_shdict_free_space{dict="cached_auths"} 1032192
apicast_shdict_free_space{dict="configuration"} 10412032
apicast_shdict_free_space{dict="init"} 4096
apicast_shdict_free_space{dict="limiter"} 1032192
apicast_shdict_free_space{dict="locks"} 1032192
apicast_shdict_free_space{dict="prometheus_metrics"} 16666624
--- error_code: 200
--- no_error_log
[error]

=== TEST 2: metric endpoints shows backend responses when the APIcast policy is in the chain
We do a couple of authorized requests to backend (2xx) and a couple of
unauthorized ones (4xx) and check that those metrics are shown correctly when
calling the prometheus metrics endpoint.
To simplify the output of the metrics endpoint, we use an environment config
that does not include the nginx metrics (tested in the previous test).
--- environment_file: t/fixtures/configs/without_nginx_metrics.lua
--- configuration
{
  "services": [
    {
      "id": 42,
      "backend_version":  1,
      "backend_authentication_type": "service_token",
      "backend_authentication_value": "token-value",
      "proxy": {
        "api_backend": "http://test:$TEST_NGINX_SERVER_PORT/",
        "proxy_rules": [
          { "pattern": "/", "http_method": "GET", "metric_system_name": "hits", "delta": 1 }
        ],
        "policy_chain": [
          { "name": "apicast.policy.apicast" }
        ]
      }
    }
  ]
}
--- upstream
  location / {
     content_by_lua_block {
       ngx.say('yay, api backend');
     }
  }
--- backend
  location /transactions/authrep.xml {
    content_by_lua_block {
      -- Check only the user key and assume the rest of params are OK
      if ngx.req.get_uri_args(0)['user_key'] == 'invalid' then
        ngx.exit(403)
      else
        ngx.exit(200)
      end
    }
  }
--- request eval
["GET /?user_key=valid", "GET /?user_key=valid", "GET /?user_key=invalid", "GET /?user_key=invalid", "GET /metrics"]
--- more_headers eval
["", "", "", "", "Host: metrics"]
--- error_code eval
[ 200, 200, 403, 403, 200 ]
--- response_body eval
[ "yay, api backend\x{0a}", "yay, api backend\x{0a}", "Authentication failed", "Authentication failed",
<<'METRICS_OUTPUT'
# HELP apicast_nginx_metric_errors_total Number of nginx-lua-prometheus errors
# TYPE apicast_nginx_metric_errors_total counter
apicast_nginx_metric_errors_total 0
# HELP apicast_threescale_backend_response Response status codes from 3scale's backend
# TYPE apicast_threescale_backend_response counter
apicast_threescale_backend_response{status="2xx"} 2
apicast_threescale_backend_response{status="4xx"} 2
METRICS_OUTPUT
]
--- no_error_log
[error]

=== TEST 3: metrics endpoint shows auth cache hits and misses when using the 3scale batching policy
We make 3 requests with the same user key. In the output we'll see a miss
from the first request and 2 hits from the others.
We use and env file without the nginx metrics to simplify the output of the
/metrics endpoint.
--- environment_file: t/fixtures/configs/without_nginx_metrics.lua
--- configuration
{
  "services": [
    {
      "id": 42,
      "backend_version":  1,
      "backend_authentication_type": "service_token",
      "backend_authentication_value": "token-value",
      "proxy": {
        "api_backend": "http://test:$TEST_NGINX_SERVER_PORT/",
        "proxy_rules": [
          { "pattern": "/", "http_method": "GET", "metric_system_name": "hits", "delta": 1 }
        ],
        "policy_chain": [
          { "name": "apicast.policy.apicast" },
          { "name": "apicast.policy.3scale_batcher", "configuration": {} }
        ]
      }
    }
  ]
}
--- upstream
  location / {
     content_by_lua_block {
       ngx.say('yay, api backend');
     }
  }
--- backend
  location /transactions/authorize.xml {
    content_by_lua_block {
      ngx.exit(200)
    }
  }

  location /transactions.xml {
    content_by_lua_block {
      ngx.exit(200)
    }
  }
--- request eval
["GET /?user_key=valid", "GET /?user_key=valid", "GET /?user_key=valid", "GET /metrics"]
--- more_headers eval
["", "", "", "Host: metrics"]
--- error_code eval
[ 200, 200, 200, 200 ]
--- response_body eval
[ "yay, api backend\x{0a}", "yay, api backend\x{0a}", "yay, api backend\x{0a}",
<<'METRICS_OUTPUT'
# HELP apicast_batching_policy_auths_cache_hits Hits in the auths cache of the 3scale batching policy
# TYPE apicast_batching_policy_auths_cache_hits counter
apicast_batching_policy_auths_cache_hits 2
# HELP apicast_batching_policy_auths_cache_misses Misses in the auths cache of the 3scale batching policy
# TYPE apicast_batching_policy_auths_cache_misses counter
apicast_batching_policy_auths_cache_misses 1
# HELP apicast_nginx_metric_errors_total Number of nginx-lua-prometheus errors
# TYPE apicast_nginx_metric_errors_total counter
apicast_nginx_metric_errors_total 0
# HELP apicast_threescale_backend_response Response status codes from 3scale's backend
# TYPE apicast_threescale_backend_response counter
apicast_threescale_backend_response{status="2xx"} 1
METRICS_OUTPUT
]
--- no_error_log
[error]
