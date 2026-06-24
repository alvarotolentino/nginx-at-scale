-- browse-ui.lua — simulate real browsers loading the SPA across many static paths.
--
-- This is the load that matters for the "1B concurrent in nginx" goal: every path
-- here is served by nginx directly — the SPA routes (/, /product/<id>, /cart all
-- resolve to index.html via try_files) and the hashed JS/CSS bundles. It stresses
-- nginx + the kernel, NOT the Rust/lux backend. (wrk does not run JS, so the SPA's
-- in-browser API calls never fire here — use the k6 scenario for the API journey.)
--
-- Paths come from the UI_PATHS env var (comma-separated). load-test.sh discovers
-- them at runtime from the target (real asset hashes + a real product id) so the
-- paths always match the current Vite build and DB seed. Falls back to "/" if unset.
--
-- Each entry may carry an optional weight as "path@N" (default 1). Higher-weight
-- paths are requested proportionally more often. load-test.sh weights the small
-- HTML routes heavily over the big JS/CSS bundles so this measures nginx connection
-- concurrency rather than being dominated by one 140 KB vendor-bundle transfer.
--   e.g. UI_PATHS="/@8,/product/x@8,/cart@8,/assets/vendor.js@1"

local pool = {}
for entry in string.gmatch(os.getenv("UI_PATHS") or "/", "([^,]+)") do
  local path, weight = string.match(entry, "^(.-)@(%d+)$")
  if not path then path, weight = entry, 1 end
  weight = tonumber(weight) or 1
  for _ = 1, weight do
    pool[#pool + 1] = path
  end
end
if #pool == 0 then pool = { "/" } end

local i = 0
request = function()
  i = i + 1
  return wrk.format("GET", pool[(i % #pool) + 1])
end
