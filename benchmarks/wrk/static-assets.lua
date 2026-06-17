-- wrk script: simulate a browser loading the SPA.
-- Alternates the HTML document with the JS vendor bundle, mimicking the two
-- requests a fresh page load makes (HTML first, then the script).
-- "assets/vendor.js" is a fixed placeholder filename — adjust to your built hash
-- (Vite emits assets/vendor-<hash>.js) if you want an exact match.

local paths = { "/", "/assets/vendor.js" }
local i = 0

request = function()
  i = i + 1
  local path = paths[(i % #paths) + 1]
  return wrk.format("GET", path)
end
