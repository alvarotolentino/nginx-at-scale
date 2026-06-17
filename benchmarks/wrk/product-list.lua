-- wrk script: realistic browse pattern against the API.
-- 80% list requests, 20% single-product detail requests. The detail id is picked
-- from a fixed pool so the request is deterministic and cache-friendly.

local ids = {
  "prod-001", "prod-002", "prod-003", "prod-004", "prod-005",
  "prod-006", "prod-007", "prod-008", "prod-009", "prod-010",
}

math.randomseed(os.time())

request = function()
  -- 20% of requests hit a random product detail; the rest hit the list.
  if math.random(100) <= 20 then
    local id = ids[math.random(#ids)]
    return wrk.format("GET", "/api/products/" .. id)
  else
    return wrk.format("GET", "/api/products")
  end
end
