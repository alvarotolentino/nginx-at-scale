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

local paths = {}
for p in string.gmatch(os.getenv("UI_PATHS") or "/", "([^,]+)") do
  paths[#paths + 1] = p
end
if #paths == 0 then paths = { "/" } end

local i = 0
request = function()
  i = i + 1
  return wrk.format("GET", paths[(i % #paths) + 1])
end
