-- Error containment for CoolPlan's own callbacks.
--
-- We do NOT touch the global error handler (that would hide other addons'
-- bugs). Instead we wrap CoolPlan's own entry points (events, the combat
-- ticker, slash, UI handlers) so a bug here is caught, stored, and shown once
-- (throttled) instead of spamming the default Lua error popup 10x/second.
-- View captured errors with /coolplan errors; re-enable popups with /coolplan debug.

local _, ns = ...

local errors = {}
ns.errors = errors
ns.debug = false

local lastNotice = 0

function ns.OnError(err)
  local stamp = (type(date) == "function") and date("%H:%M:%S") or "?"
  errors[#errors + 1] = stamp .. "  " .. tostring(err)
  while #errors > 50 do table.remove(errors, 1) end

  if ns.debug then
    -- forward to the normal handler so the popup shows (developer mode)
    geterrorhandler()(err)
    return
  end

  -- quiet, throttled chat notice so the user knows something was swallowed
  local now = (type(GetTime) == "function") and GetTime() or 0
  if now - lastNotice > 5 then
    lastNotice = now
    if ns.Print then
      ns.Print("|cffff6666an error was caught and suppressed|r (type |cffffd200/coolplan errors|r to view).")
    end
  end
end

-- Run fn(...) under pcall, routing any error to OnError. Returns fn's results
-- on success, nil on failure.
function ns.safecall(fn, ...)
  if type(fn) ~= "function" then return end
  local result = { pcall(fn, ...) }
  if not result[1] then
    ns.OnError(result[2])
    return
  end
  return select(2, unpack(result))
end

-- Wrap a function so it self-guards - for SetScript handlers and timers.
function ns.wrap(fn)
  if type(fn) ~= "function" then return fn end
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then ns.OnError(err) end
  end
end

-- Dump captured errors to chat.
function ns.PrintErrors()
  if #errors == 0 then
    ns.Print("no errors captured.")
    return
  end
  ns.Print(("last %d error(s):"):format(#errors))
  for _, e in ipairs(errors) do
    print("|cffff8888" .. e .. "|r")
  end
end
