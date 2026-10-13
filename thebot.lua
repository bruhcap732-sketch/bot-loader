-- WITHDRAWAL COMPLETION RECOVERY v8
-- CLIENT INVENTORY HEARTBEAT SYNC\n-- PS99 Auto Sell Bot v1.0
-- WITHDRAWAL CLIENT INVENTORY FALLBACK HARDENED v6
-- SIMPLE BUILD (2026-10-11): same base as the earlier working script, with
-- ONE real fix - Cosmic Value reading is now actually wired into the real
-- deposit path (checkItems), not just the unused side-path that had it
-- before. Found by reading the old file closely: checkItems() (what the
-- real deposit flow actually calls) built items as plain identityKey
-- strings with no cosmicValue/demand at all - only checkTheirItems(), a
-- function the live deposit flow never calls, had real CV reading. That's
-- why Cosmic Value never reached a real deposit. Everything else in this
-- file is unchanged from the version that was already working.
-- Loaded via: loadstring(game:HttpGet("..."))()

-- ============================================================
-- CONFIGURATION (UPDATE THESE!)
-- ============================================================
local BOT_ID           = "98a5a262a479bd8203a8f5d9"
local BOT_API_SECRET   = "3f0bf649661ee04db63e561fe0f4e5475e666cd73317df8e1ea892a0c69f0876"
local PRIVATE_SERVER_LINK = "https://www.roblox.com/share?code=ec02451b42e74946973aee7260ed4d80&type=Server"
-- Base URL only. Do NOT append /api. The client adds /api/bots/... itself.
local website          = "https://bloxyflip.fun"
local discordWebhook   = ""  -- optional: Discord webhook for trade logs

local TRADE_TIMEOUT_SECONDS = 120
local MAX_TRADE_PETS = 100
local ROBLOX_GEMS_PER_SITE_GEM = 1 -- 1m Roblox gems = 1 site gem; 1b = 1000
-- ============================================================
-- SERVICES
-- ============================================================
local httpService       = game:GetService("HttpService")
local players           = game:GetService("Players")
local replicatedStorage = game:GetService("ReplicatedStorage")
local virtualUser       = game:GetService("VirtualUser")
local textChatService   = game:GetService("TextChatService")
local localPlayer = players.LocalPlayer

-- ============================================================
-- EXECUTOR HTTP REQUEST
-- Script is loaded via loadstring(game:HttpGet(...))()
-- so the executor's `request` global is already available.
-- ============================================================
local request = request or http_request or (syn and syn.request)
if type(request) ~= "function" then
    for _, name in ipairs({"request", "http_request", "https_request"}) do
        local ok, val = pcall(function() return getgenv()[name] end)
        if ok and type(val) == "function" then request = val; break end
    end
end
if type(request) ~= "function" then
    error("[BOT] CRITICAL: No executor HTTP function found. Run via loadstring(game:HttpGet(...))() in your executor.")
end

-- ============================================================
-- WAIT FOR GUI
-- ============================================================
local playerGUI     = localPlayer:WaitForChild("PlayerGui", 30)
local tradingWindow = playerGUI:WaitForChild("TradeWindow", 30)
if not tradingWindow then
    error("[BOT] CRITICAL: TradeWindow not found. Make sure you are in a PS99 private server!")
end

-- Lazily resolved when first trade happens
local tradingMessage = playerGUI:FindFirstChild("Message")

-- Trade UI refs - refreshed per-trade
local tradingFrame, playerItemsFrame, tradingStatus, theirItemsFrame, theirStatus

-- ============================================================
-- LOAD GAME MODULES
-- ============================================================
local library = replicatedStorage:WaitForChild("Library", 30)
if not library then error("[BOT] CRITICAL: Library not found in ReplicatedStorage!") end

local clientFolder = library:WaitForChild("Client", 10)
if not clientFolder then error("[BOT] CRITICAL: Client folder not found in Library!") end

-- ============================================================
-- PS99 MODULE CHECK
-- ============================================================

local saveModuleScript = clientFolder:FindFirstChild("Save")
local tradingCmdsScript = clientFolder:FindFirstChild("TradingCmds")

if not saveModuleScript then
    warn("[BOT] Save module not found")
else
    print("[BOT] Save module found: " .. saveModuleScript:GetFullName())
    print("[BOT] Save class: " .. saveModuleScript.ClassName)
end

if not tradingCmdsScript then
    warn("[BOT] TradingCmds module not found")
else
    print("[BOT] TradingCmds found: " .. tradingCmdsScript:GetFullName())
    print("[BOT] TradingCmds class: " .. tradingCmdsScript.ClassName)
end

local saveModule = nil
local tradingCommands = nil

-- Try the normal ModuleScript interface.  If PS99's current execution
-- context prevents requiring these modules, keep them nil and report the
-- exact failure instead of silently pretending the bot is ready.
local function tryRequireModule(moduleScript, moduleName)
    if not moduleScript then
        warn("[BOT] " .. moduleName .. " ModuleScript does not exist")
        return nil
    end

    if not moduleScript:IsA("ModuleScript") then
        warn("[BOT] " .. moduleName .. " is not a ModuleScript")
        return nil
    end

    local ok, result = pcall(function()
        return require(moduleScript)
    end)

    if not ok then
        warn("[BOT] Failed to require " .. moduleName .. ": " .. tostring(result))
        return nil
    end

    if type(result) ~= "table" then
        warn("[BOT] " .. moduleName .. " loaded, but returned " .. typeof(result) .. " instead of a table")
        return nil
    end

    print("[BOT] [OK] " .. moduleName .. " module loaded")
    return result
end

saveModule = tryRequireModule(saveModuleScript, "Save")
tradingCommands = tryRequireModule(tradingCmdsScript, "TradingCmds")

if not saveModule or not tradingCommands then
    warn("============================================================")
    warn("[BOT] PS99 TRADE INTEGRATION UNAVAILABLE")
    warn("[BOT] Normal ModuleScript access failed.")
    warn("[BOT] No protected-module bypass is attempted.")
    warn("[BOT] The bot will wait instead of silently attempting trades.")
    warn("============================================================")
else
    print("[BOT] [OK] PS99 trade integration loaded")
end

-- ============================================================
-- STATE
-- ============================================================
local supporteditems     = {}
local catalogByDisplay   = {}
local catalogByKey       = {}   -- configName|variant -> live catalog entry
local catalogByIdentity  = {}   -- explicit alias for the real join key

local goNext             = true
-- Locked immediately when an incoming trade is detected, before any API calls.
-- This prevents concurrent main-loop iterations from processing the same request.
local activeIncomingTrade = false
local activeIncomingUserId = nil
local activeIncomingSince = 0
local withdrawalHoldUntil = {}
local WITHDRAWAL_HOLD_COOLDOWN = 30
local method             = nil
local tradeId            = 0
local lastTradeUsername  = nil
local lastTradeUserId    = nil
local lastGameTradeId    = nil
local lastTradeItems     = {}
local lastTradeGems      = 0
local lastWithdrawalData = nil
local lastItemsGiven     = {}
local lastBotGemsAdded   = 0  -- gems bot actually sent (derived from botGemBalance, not UI)
local botGemBalance      = 0  -- latest backend-held gem balance
local botGemBalancePresent = false -- true once heartbeat supplies a valid heldGemsBalance
local lastGemsRequested  = 0  -- what we asked the game to add (reliable even after window closes)
local lastWithdrawalMissing = { pets = {}, gems = 0 }  -- tracks what bot couldn't fulfil

local hasReadied     = false
local hasConfirmed   = false
local tradeProcessed = false
local tradeCancelled = false   -- set immediately on cancel to block isInTrade fallback
local botReadied     = false
local botConfirmed   = false

-- Tracks the LAST withdrawal confirmed for each user.
-- We only suppress the exact same withdrawal ID if the backend briefly
-- returns it again. A NEW withdrawal from the same user is allowed immediately.
-- Value = { id = tostring(withdrawalId), at = os.time() }
local completedWithdrawals = {}

local assetIds        = {}
local goldAssetids    = {}
local nameAssetIds    = {}
local hugesTitanicsIds = {}

-- ============================================================
-- UTILITY
-- ============================================================
local function humanDelay(minMs, maxMs)
    task.wait(math.random(minMs or 100, maxMs or 300) / 1000)
end

local function randomWait(min, max)
    task.wait(math.random(math.floor(min * 100), math.floor(max * 100)) / 100)
end

-- Format a Roblox gem amount using the site's gem conversion.
-- 1,000,000 Roblox gems = 1 site gem when ROBLOX_GEMS_PER_SITE_GEM = 1.
local function formatDepositGemCredit(robloxGems)
    local amount = tonumber(robloxGems) or 0
    if amount <= 0 then return "0 site gems" end

    local siteGems = amount / 1000000 / ROBLOX_GEMS_PER_SITE_GEM
    if math.abs(siteGems - math.floor(siteGems + 0.5)) < 1e-9 then
        return string.format("%d site gems", math.floor(siteGems + 0.5))
    end
    return string.format("%.3f site gems", siteGems):gsub("(%..-)0+$", "%1"):gsub("%.$", "")
end

-- cvCache lives at module scope (not inside the CV reader section further
-- down) so resetTradeState() - declared here, before it's used - can clear
-- it at every trade boundary. This is the fix for the OTHER known bug in
-- this style of CV reader (confirmed live, earlier tonight): without this
-- clear, a price read once stays cached and gets silently reused for every
-- later deposit of that same pet name, even a completely different trade,
-- for the rest of the bot's uptime.
local cvCache = {}

local function resetTradeState()
    lastTradeItems        = {}
    lastTradeUserId       = nil
    lastGameTradeId       = nil
    lastTradeGems         = 0
    lastWithdrawalData    = nil
    lastItemsGiven        = {}
    lastBotGemsAdded      = 0
    lastGemsRequested     = 0
    lastWithdrawalMissing = { pets = {}, gems = 0 }
    tradeProcessed        = false
    tradeCancelled        = false
    botReadied            = false
    botConfirmed          = false
    hasReadied            = false
    hasConfirmed          = false
    cvCache               = {}
end

local function releaseIncomingTradeLock()
    activeIncomingTrade = false
    activeIncomingUserId = nil
    activeIncomingSince = 0
end

local function decodeBody(response)
    if not response or not response.Body then return nil end
    local ok, data = pcall(httpService.JSONDecode, httpService, response.Body)
    return ok and data or nil
end

-- ============================================================
-- SHA256 (multi-executor)
-- ============================================================
local function sha256Hex(data)
    local res = nil
    pcall(function()
        local c = crypt or (syn and syn.crypt)
        if c and c.hash then res = c.hash(data, "sha256") end
    end)
    if not res then pcall(function()
        if rcrypt and rcrypt.hash then res = rcrypt.hash("sha256", data) end
    end) end
    if not res then
        warn("[CRYPTO] No SHA256 lib found - signature zeroed")
        return string.rep("0", 64)
    end
    if #res == 64 and res:match("^[0-9a-fA-F]+$") then return res:lower() end
    local hex = ""
    for i = 1, #res do hex = hex .. string.format("%02x", string.byte(res, i)) end
    return hex
end

-- ============================================================
-- API
-- ============================================================
local function randomNonce()
    local ok, guid = pcall(function() return httpService:GenerateGUID(false) end)
    if ok and guid then return guid:gsub("%-", "") end
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local out = {}
    for i = 1, 32 do
        local n = math.random(1, #chars)
        out[i] = chars:sub(n, n)
    end
    return table.concat(out)
end

local function hexToBytes(hex)
    local out = {}
    for i = 1, #hex, 2 do
        out[#out + 1] = string.char(tonumber(hex:sub(i, i + 1), 16))
    end
    return table.concat(out)
end

local function sha256Bytes(data)
    local res = nil
    pcall(function()
        local c = crypt or (syn and syn.crypt)
        if c and c.hash then res = c.hash(data, "sha256") end
    end)
    if not res then
        pcall(function()
            if rcrypt and rcrypt.hash then res = rcrypt.hash("sha256", data) end
        end)
    end
    if not res then
        error("No SHA256 implementation is available in this executor")
    end
    if #res == 64 and res:match("^[0-9a-fA-F]+$") then
        return hexToBytes(res)
    end
    return res
end

local function sha256Hex(data)
    local ok, raw = pcall(sha256Bytes, data)
    if not ok then
        warn("[CRYPTO] " .. tostring(raw))
        return string.rep("0", 64)
    end
    local hex = ""
    for i = 1, #raw do
        hex = hex .. string.format("%02x", string.byte(raw, i))
    end
    return hex
end

local function hmacSha256Hex(secret, message)
    local blockSize = 64
    if #secret > blockSize then secret = sha256Bytes(secret) end
    if #secret < blockSize then secret = secret .. string.rep("\0", blockSize - #secret) end

    local inner = {}
    local outer = {}
    for i = 1, blockSize do
        local b = string.byte(secret, i)
        inner[i] = string.char(bit32.bxor(b, 0x36))
        outer[i] = string.char(bit32.bxor(b, 0x5c))
    end

    local digest = sha256Bytes(table.concat(inner) .. message)
    local final = sha256Bytes(table.concat(outer) .. digest)
    local hex = ""
    for i = 1, #final do
        hex = hex .. string.format("%02x", string.byte(final, i))
    end
    return hex
end

local function makeAuthenticatedRequest(endpoint, body, method)
    method = tostring(method or "POST"):upper()

    -- The backend signs the EXACT raw request body bytes. Build JSON once,
    -- hash that exact string, and send that exact same string.
    local isBodyless = (method == "GET" or method == "HEAD")
    local rawBody = ""

    if not isBodyless then
        if body == nil then body = {} end
        rawBody = httpService:JSONEncode(body)
    end

    -- Fresh auth material on EVERY request, including retries.
    local timestamp = tostring(os.time())
    local nonce = randomNonce()
    local bodyHash = sha256Hex(rawBody)
    local canonical = table.concat({ method, endpoint, timestamp, nonce, bodyHash }, "\n")
    local signature = hmacSha256Hex(BOT_API_SECRET, canonical)

    local base = website:gsub("/+$", "")
    local url = base .. endpoint

    local headers = {
        ["X-Bot-Client-Id"] = BOT_ID,
        ["X-Bot-Timestamp"] = timestamp,
        ["X-Bot-Nonce"] = nonce,
        ["X-Bot-Signature"] = signature,
    }

    if not isBodyless then
        headers["Content-Type"] = "application/json"
    end

    local options = {
        Url = url,
        Method = method,
        Headers = headers,
    }

    if not isBodyless then
        -- Both common executor field spellings point to the SAME exact string.
        -- Nothing is re-serialized after hashing.
        options.Body = rawBody
        options.body = rawBody
    end

    print("[AUTH] " .. method .. " " .. endpoint ..
        " | ts=" .. timestamp ..
        " nonce=" .. tostring(nonce) ..
        " bodyHash=" .. tostring(bodyHash):sub(1, 12) ..
        " sig=" .. tostring(signature):sub(1, 12))

    local success, response = pcall(function()
        return request(options)
    end)

    local status = success and response and tostring(response.StatusCode or "?") or "FAIL"
    local preview = success and response and response.Body and response.Body:sub(1, 300) or tostring(response)
    print("[API] " .. method .. " " .. endpoint .. " -> " .. status .. " | " .. preview)
    return success, response
end

local function getPendingWithdrawal(userId)
    if not userId then
        warn("[WITHDRAWAL] No BloxyFlip userId supplied - skipping scoped lookup")
        return nil
    end

    local LOOKUP_ATTEMPTS = 3
    local LOOKUP_DELAY = 0.10

    for attempt = 1, LOOKUP_ATTEMPTS do
        local payload = { userId = tostring(userId) }

        print("[WITHDRAWAL] Lookup attempt " .. tostring(attempt) .. "/" .. tostring(LOOKUP_ATTEMPTS) .. " | userId=" .. tostring(userId))

        local s, r = makeAuthenticatedRequest(
            "/api/bots/get-pending-withdrawal",
            payload,
            "POST"
        )

        if s and r and r.StatusCode == 200 then
            local data = decodeBody(r)

            if data and data.success then
                if data.withdrawal then
                    local wd = data.withdrawal
                    print("[WITHDRAWAL] Found withdrawal | attempt=" .. tostring(attempt) ..
                        " | id=" .. tostring(wd.id) ..
                        " | status=" .. tostring(wd.status) ..
                        " | assignedClientId=" .. tostring(wd.assignedClientId) ..
                        " | gems=" .. tostring(wd.gemsAmount or wd.gems or 0))
                    return {
                        success = true,
                        data = wd,
                        blocked = data.blocked == true,
                        pendingWithdrawalExists = true,
                        partial = data.partial == true,
                        raw = data,
                    }
                end

                if data.pendingWithdrawalExists == true or data.blocked == true then
                    local reason = data.reason
                    local shortCount = type(data.shortItems) == "table" and #data.shortItems or 0
                    local pending = data.pendingWithdrawal

                    print("[WITHDRAWAL] PENDING withdrawal with no backend-fulfillable payload | blocked=" ..
                        tostring(data.blocked == true) ..
                        " | reason=" .. tostring(reason or "none") ..
                        " | pendingWithdrawalExists=" .. tostring(data.pendingWithdrawalExists) ..
                        " | shortItems=" .. tostring(shortCount) ..
                        " | neededGems=" .. tostring(data.neededGems or 0) ..
                        " | heldGems=" .. tostring(data.heldGems or 0) ..
                        " | hasPendingPayload=" .. tostring(type(pending) == "table"))

                    local assignedElsewhere = type(pending) == "table"
                        and (pending.assignedToAnotherClient == true
                            or (pending.assignedToThisClient == false
                                and pending.assignedToAnotherClient == true))

                    if type(pending) == "table"
                        and not assignedElsewhere
                        and tostring(reason or "") == "insufficient_held_items"
                    then
                        local copied = {}
                        for k, v in pairs(pending) do
                            copied[k] = v
                        end
                        copied.items = type(pending.items) == "table" and pending.items or {}

                        print("[WITHDRAWAL-LOCAL-FALLBACK] Backend says insufficient_held_items; passing pending withdrawal to local inventory verifier | id=" ..
                            tostring(copied.id) .. " | requestedItems=" .. tostring(#copied.items))

                        return {
                            success = true,
                            data = copied,
                            blocked = false,
                            pendingWithdrawalExists = true,
                            partial = false,
                            localInventoryFallback = true,
                            blockReason = reason,
                            blockInfo = data,
                            raw = data,
                        }
                    end

                    return {
                        success = true,
                        data = nil,
                        blocked = data.blocked == true,
                        pendingWithdrawalExists = true,
                        blockReason = reason,
                        blockInfo = data,
                        raw = data,
                    }
                end

                print("[WITHDRAWAL] Confirmed no pending withdrawal")
                return {
                    success = true,
                    data = nil,
                    blocked = false,
                    pendingWithdrawalExists = false,
                    raw = data,
                }
            else
                warn("[WITHDRAWAL] Invalid/failed API response on attempt " .. tostring(attempt) ..
                    ": " .. tostring(r.Body))
            end
        else
            warn("[WITHDRAWAL] get-pending-withdrawal failed on attempt " .. tostring(attempt) ..
                " | status=" .. tostring(r and r.StatusCode or "?") ..
                " | body=" .. tostring(r and r.Body or ""))
        end

        if attempt < LOOKUP_ATTEMPTS then
            task.wait(LOOKUP_DELAY)
        end
    end

    print("[WITHDRAWAL] Lookup failed after " .. tostring(LOOKUP_ATTEMPTS) .. " checks - MUST NOT enter DEPOSIT MODE")
    return {
        success = false,
        data = nil,
        blocked = false,
        pendingWithdrawalExists = nil,
        error = "WITHDRAWAL_LOOKUP_FAILED",
    }
end

local function checkUserBanned(userId)
    local payload = { robloxUserId = tostring(userId) }
    local s, r = makeAuthenticatedRequest("/api/bots/check-user-banned", payload, "POST")
    if s and r and r.StatusCode == 200 then
        local data = decodeBody(r)
        if data then return data end
    end
    return { success = false, found = false, banned = false }
end

local function displayToCatalog(itemKey)
    -- The real pet identity is configName + variant.
    local entry = catalogByKey and catalogByKey[tostring(itemKey)]
    if not entry then
        entry = catalogByDisplay and catalogByDisplay[itemKey]
    end
    if entry then
        return {
            petConfigId = tostring(entry.configName or entry.petConfigId),
            variant = tostring(entry.variant or "normal"),
            quantity = 1,
        }
    end
    return nil
end

local makeCatalogDisplay

local function tradeItemDisplay(itemKey)
    local entry = catalogByKey and catalogByKey[tostring(itemKey)]
    if entry then return makeCatalogDisplay(entry) end
    return tostring(itemKey)
end

local function makeStableTradeTransactionId(gameTradeId)
    local rawTradeId = tostring(gameTradeId or "")
    if rawTradeId == "" or rawTradeId == "0" then
        return nil
    end

    local jobId = "unknown-job"
    pcall(function()
        if game and game.JobId and tostring(game.JobId) ~= "" then
            jobId = tostring(game.JobId)
        end
    end)

    return tostring(BOT_ID) .. ":" .. jobId .. ":" .. rawTradeId
end

local function processDeposit(userId, gameTradeId, items, gemAmount, bypassMin)
    if not userId then return false, "No Roblox user id" end
    -- No gem minimum: deposits may contain any gem amount, including 0.
    if #items == 0 and (gemAmount or 0) == 0 then
        return false, "Nothing to deposit"
    end

    local payloadItems = {}
    local counts = {}
    for _, entry in ipairs(items or {}) do
        -- Support both plain string names and table entries with CV data.
        -- checkItems() now always sends table entries - see its own doc
        -- comment for why.
        local displayName = type(entry) == "table" and entry.name or tostring(entry)
        local cosmicValue = type(entry) == "table" and entry.cosmicValue or nil
        local demand      = type(entry) == "table" and entry.demand or nil

        local item = displayToCatalog(displayName)
        if not item then
            return false, "Unsupported/unmapped item: " .. tostring(displayName)
        end
        local key = item.petConfigId .. "|" .. item.variant
        if counts[key] then
            counts[key].quantity = counts[key].quantity + 1
        else
            item.cosmicValue = cosmicValue
            item.demand = demand
            -- Tells the backend the identity (name + variant) is a real,
            -- confirmed read - not an OCR guess. Needed for the backend's
            -- own "price unknown but identity confirmed -> credit at 0
            -- instead of holding forever" fallback to apply. Without this,
            -- a deposit with no Cosmic Value read sits invisible in a
            -- pricing queue rather than being handled either way.
            item.variantRead = true
            counts[key] = item
            table.insert(payloadItems, item)
        end
    end

    local transactionTradeId = makeStableTradeTransactionId(gameTradeId)
    if not transactionTradeId then
        return false, "Missing PS99 trade id - refusing to create a non-unique deposit transaction"
    end

    local payload = {
        tradeId = transactionTradeId,
        robloxUserId = tostring(userId),
        items = payloadItems,
        gems = tonumber(gemAmount) or 0,
    }

    -- Retry transient/auth failures with a fresh timestamp + nonce + signature.
    -- The backend's trade-key idempotency guarantees a successful first attempt
    -- cannot be credited twice by these retries.
    local lastData = nil
    local lastStatus = nil
    for attempt = 1, 3 do
        if attempt > 1 then
            task.wait(0.5 * (attempt - 1))
            print("[DEPOSIT] Retrying process-deposit attempt " .. attempt .. "/3 with fresh auth")
        end

        local s, r = makeAuthenticatedRequest("/api/bots/process-deposit", payload, "POST")
        local data = decodeBody(r)
        local status = s and r and tonumber(r.StatusCode) or nil
        lastData = data
        lastStatus = status

        -- The backend returns 201 for a genuinely new deposit and 200 only
        -- for a duplicate resubmission - accept both as success.
        if s and r and (status == 200 or status == 201) and data and data.success then
            local dep = data.deposit or {}
            return true, dep.value or 0, data
        end

        local transient = status == 401 or status == 408 or status == 425 or
                          status == 429 or (status and status >= 500 and status <= 599)
        if not transient then break end
    end

    return false, (lastData and (lastData.error or lastData.message)) or
        ("HTTP " .. tostring(lastStatus or "?")), lastData
end

local function confirmWithdrawal(userId, withdrawalData, tradeDeliveryId, fulfilledItems, missingPets, missingGems, sentGems)
    if not withdrawalData or not withdrawalData.id then
        return false, "Missing withdrawal id"
    end
    if not tradeDeliveryId then
        return false, "Missing delivery trade id"
    end

    local payload = {
        withdrawalId = tostring(withdrawalData.id),
        botId = tostring(BOT_ID),
        clientId = tostring(BOT_ID),
        assignedClientId = tostring(BOT_ID),
        tradeId = tostring(BOT_ID) .. ":" .. tostring(tradeDeliveryId),
        externalTradeId = tostring(tradeDeliveryId),
        gameTradeId = tostring(tradeDeliveryId),
        fulfilledItems = fulfilledItems or {},
        missingPets = missingPets or {},
        missingGems = tonumber(missingGems) or 0,
        sentGems = tonumber(sentGems) or 0,
    }

    for attempt = 1, 8 do
        local s, r = makeAuthenticatedRequest("/api/bots/complete-withdrawal", payload, "POST")
        local data = decodeBody(r)
        local status = s and r and tonumber(r.StatusCode) or nil

        print("[CONFIRM-WITHDRAWAL] Attempt " .. tostring(attempt) .. "/8 -> " .. tostring(status or "FAIL") ..
            " | withdrawalId=" .. tostring(withdrawalData.id))

        if s and r and status == 200 and data and data.success then
            return true, data
        end

        local errorCode = data and tostring(data.error or "") or ""
        if status == 409 and errorCode == "NOT_ASSIGNED" then
            print("[CONFIRM-WITHDRAWAL] NOT_ASSIGNED; refreshing pending withdrawal before retry")
            local refreshOk, refreshResp = makeAuthenticatedRequest(
                "/api/bots/get-pending-withdrawal",
                { userId = tostring(userId) },
                "POST"
            )
            if refreshOk and refreshResp and refreshResp.StatusCode == 200 then
                local refreshed = decodeBody(refreshResp)
                if refreshed and refreshed.success and refreshed.withdrawal
                    and tostring(refreshed.withdrawal.id) == tostring(withdrawalData.id) then
                    local rw = refreshed.withdrawal
                    print("[CONFIRM-WITHDRAWAL] Refreshed exact withdrawal | assignedClientId=" ..
                        tostring(rw.assignedClientId) .. " | assignedToThisClient=" ..
                        tostring(rw.assignedToThisClient))
                    if rw.assignedToThisClient == true or
                       tostring(rw.assignedClientId or "") == tostring(BOT_ID) then
                        payload.assignedClientId = tostring(BOT_ID)
                    end
                end
            end
        end

        local errorMessage
        if data then
            errorMessage = tostring(data.error or data.message or "Unknown API error")
        elseif r then
            errorMessage = "HTTP " .. tostring(status or "?") .. ": " .. tostring(r.Body or "")
        else
            errorMessage = "HTTP request failed"
        end

        warn("[CONFIRM-WITHDRAWAL] Failed attempt " .. tostring(attempt) .. "/8 | withdrawalId=" ..
            tostring(withdrawalData.id) .. " | error=" .. errorMessage)

        if attempt < 8 then
            if status == 409 and errorCode == "NOT_ASSIGNED" then
                task.wait(0.75)
            else
                task.wait(attempt)
            end
        end
    end

    return false, "Unable to complete withdrawal after 8 attempts"
end

local function cancelWithdrawalTrade(withdrawalData, reason, retry)
    if not withdrawalData or not withdrawalData.id then
        return false
    end

    local safeReason = tostring(reason or "Trade cancelled")
    if #safeReason > 500 then
        safeReason = safeReason:sub(1, 497) .. "..."
    end

    local payload = {
        withdrawalId = tostring(withdrawalData.id),
        retry = retry ~= false,
        reason = safeReason,
    }

    local s, r = makeAuthenticatedRequest(
        "/api/bots/cancel-withdrawal-trade",
        payload,
        "POST"
    )

    local data = decodeBody(r)

    if not (s and r and r.StatusCode == 200 and data and data.success == true) then
        warn(
            "[WITHDRAWAL-CANCEL] Failed | status=" ..
            tostring(r and r.StatusCode or "?") ..
            " | body=" ..
            tostring(r and r.Body or "")
        )
        return false
    end

    print(
        "[WITHDRAWAL-CANCEL] Success | withdrawalId=" ..
        tostring(withdrawalData.id) ..
        " | retry=" ..
        tostring(retry ~= false)
    )

    return true
end

local function makeGetRequest(endpoint)
    return makeAuthenticatedRequest(endpoint, nil, "GET")
end

-- ============================================================
-- CHAT & DISCORD
-- ============================================================
local function sendMessage(message)
    humanDelay(200, 500)
    local sent = false
    pcall(function()
        local ch = textChatService.TextChannels and textChatService.TextChannels:FindFirstChild("RBXGeneral")
        if ch then ch:SendAsync(tostring(message)); sent = true end
    end)
    if not sent then
        pcall(function()
            game:GetService("ReplicatedStorage")
                :FindFirstChild("DefaultChatSystemChatEvents")
                :FindFirstChild("SayMessageRequest")
                :FireServer(tostring(message), "All")
        end)
    end
end

local function sendDiscord(message, color)
    pcall(function()
        request({
            Url    = discordWebhook,
            Method = "POST",
            Body   = httpService:JSONEncode({
                embeds = {{
                    title       = "BloxyFlip Bot",
                    description = message,
                    color       = color or 3447003,
                    timestamp   = os.date("!%Y-%m-%dT%H:%M:%S")
                }}
            }),
            Headers = { ["Content-Type"] = "application/json" }
        })
    end)
end

-- ============================================================
-- TRADE HELPERS
-- ============================================================
local function refreshTradeElements()
    pcall(function()
        if not tradingWindow then return end

        local frame = tradingWindow:FindFirstChild("Frame")
        if not frame then
            for _, obj in ipairs(tradingWindow:GetDescendants()) do
                if obj:IsA("Frame") and obj.Name == "Frame" then
                    frame = obj
                    break
                end
            end
        end
        if not frame then return end
        tradingFrame = frame

        local p = frame:FindFirstChild("PlayerItems")
        local t = frame:FindFirstChild("TheirItems")
        if p then playerItemsFrame = p end
        if t then theirItemsFrame = t end

        tradingStatus = playerItemsFrame and playerItemsFrame:FindFirstChild("Status") or tradingStatus
        theirStatus  = theirItemsFrame and theirItemsFrame:FindFirstChild("Status") or theirStatus
    end)
end

local function readTradeItemsFrame(frame)
    if not frame then return {} end
    local items = frame:FindFirstChild("Items")
    if not items then return {} end

    local foundItems = {}
    for _, item in ipairs(items:GetChildren()) do
        if item.Name ~= "ItemSlot" then continue end

        local iconImage = nil
        pcall(function()
            local d = item:FindFirstChild("Icon")
            if d and d:IsA("ImageLabel") then iconImage = d.Image end
            if not iconImage or iconImage == "" then
                for _, desc in ipairs(item:GetDescendants()) do
                    if desc:IsA("ImageLabel") and desc.Image ~= "" and desc.AbsoluteSize.X > 20 then
                        iconImage = desc.Image
                        break
                    end
                end
            end
        end)

        if not iconImage or iconImage == "" then continue end

        local name = getName(nameAssetIds, iconImage)
        if not name or name == "???" then
            continue
        end

        local rarity = "Normal"
        pcall(function()
            local iconObj = item:FindFirstChild("Icon") or item:FindFirstChildWhichIsA("ImageLabel")
            if iconObj and iconObj:FindFirstChild("RainbowGradient") then
                rarity = "Rainbow"
            elseif table.find(goldAssetids, iconImage) then
                rarity = "Golden"
            end
        end)

        local shiny = false
        pcall(function()
            shiny = item:FindFirstChild("ShinePulse") ~= nil
                or item:FindFirstChild("ShinyEffect") ~= nil
                or item:FindFirstChild("Shiny") ~= nil
        end)

        local display = (shiny and "Shiny " or "") .. (rarity ~= "Normal" and (rarity .. " ") or "") .. name
        table.insert(foundItems, display)
    end

    return foundItems
end

local function getTradeSides()
    refreshTradeElements()
    if not tradingFrame then return {}, {} end
    return readTradeItemsFrame(playerItemsFrame), readTradeItemsFrame(theirItemsFrame)
end

local function describeTradeSides(playerSide, otherSide)
    local a = (#playerSide > 0 and table.concat(playerSide, ", ") or "<none>")
    local b = (#otherSide > 0 and table.concat(otherSide, ", ") or "<none>")
    return "PlayerItems=" .. a .. " | TheirItems=" .. b
end

local function findBotTradeItemsContainer()
    refreshTradeElements()
    if not tradingFrame then return nil end

    for _, frame in ipairs({playerItemsFrame, theirItemsFrame}) do
        if frame then
            local items = frame:FindFirstChild("Items")
            if items then return items end
        end
    end

    return nil
end
local function getTradeId()
    local ok, state = pcall(function() return tradingCommands.GetState() end)
    return (ok and state and state._id) or 0
end

local function isInTrade()
    local ok, state = pcall(function() return tradingCommands.GetState() end)
    return ok and state ~= nil and (state._id or 0) ~= 0
end

local function getTrades()
    local trades = {}
    local ok, all = pcall(function() return tradingCommands.GetAllRequests() end)
    if not ok or type(all) ~= "table" then return trades end
    for player, trade in next, all do
        if (type(trade) == "table" and trade[localPlayer]) or trade == true then
            table.insert(trades, player)
        end
    end
    return trades
end

local function acceptTradeRequest(player)
    print("[ACCEPT] Accepting trade from " .. tostring(player.Name))

    local function checkAccepted()
        for _ = 1, 4 do
            if isInTrade() then
                local id = getTradeId()
                if id and id ~= 0 then return id end
            end
            task.wait(0.025)
        end
        return nil
    end

    local function tryCommand(fn, label)
        local ok, err = pcall(fn)
        if not ok then
            warn("[ACCEPT] " .. label .. " failed: " .. tostring(err))
        end
        return checkAccepted()
    end

    local id = nil
    if type(tradingCommands.AcceptRequest) == "function" then
        id = tryCommand(function() tradingCommands.AcceptRequest(player) end, "AcceptRequest")
    else
        warn("[ACCEPT] AcceptRequest is not available in TradingCmds; skipping")
    end
    if id then
        print("[ACCEPT] Trade opened on fast path: " .. tostring(id))
        return id
    end

    for attempt = 1, 6 do
        if type(tradingCommands.Request) == "function" then
            id = tryCommand(function() tradingCommands.Request(player) end, "Request")
            if id then return id end
        end

        if type(tradingCommands.Accept) == "function" then
            id = tryCommand(function() tradingCommands.Accept(player) end, "Accept")
            if id then return id end
        end

        id = tryCommand(function()
            local evts = replicatedStorage:FindFirstChild("Network") or replicatedStorage:FindFirstChild("Remotes")
            if evts then
                local e = evts:FindFirstChild("AcceptTrade") or evts:FindFirstChild("Trading_Accept")
                if e and e:IsA("RemoteEvent") then e:FireServer(player) end
            end
        end, "RemoteAccept")
        if id then return id end

        print("[ACCEPT] Fast fallback " .. attempt .. "/6 failed...")
        task.wait(0.05)
    end

    print("[ACCEPT] [ERR] All fast acceptance attempts failed")
    return nil
end

local function readyTrade()
    local sent, err = pcall(function()
        tradingCommands.SetReady(true)
    end)

    if not sent then
        warn("[READY] SetReady(true) failed: " .. tostring(err))
        return false
    end

    print("[READY] SetReady(true) sent successfully")
    task.wait(0.10)

    local ok, state = pcall(function()
        return tradingCommands.GetState()
    end)

    if ok and type(state) == "table" then
        local myId = tostring(localPlayer.UserId)
        if type(state._ready) == "table" and state._ready[myId] then
            print("[READY] Bot READY confirmed via GetState")
            return true
        end
    end

    print("[READY] GetState could not verify ready; continuing after successful SetReady(true)")
    return true
end

local function confirmTrade()
    humanDelay(50, 150)
    pcall(function() tradingCommands.SetConfirmed(true) end)
end

local function declineTrade()
    pcall(function() tradingCommands.Decline() end); task.wait(0.1)
    pcall(function() tradingCommands.Close() end);   task.wait(0.1)
    pcall(function() tradingCommands.Cancel() end);  task.wait(0.1)
    pcall(function()
        local evts = replicatedStorage:FindFirstChild("Network") or replicatedStorage:FindFirstChild("Remotes")
        if evts then
            local e = evts:FindFirstChild("CloseTrade") or evts:FindFirstChild("Trading_Close") or evts:FindFirstChild("DeclineTrade")
            if e and e:IsA("RemoteEvent") then e:FireServer() end
        end
    end)
end

local function addPet(uuid)
    local lastErr = nil

    local function getBotTradeIndex(state)
        if type(state) ~= "table" or type(state._players) ~= "table" then
            return nil
        end

        for index, player in pairs(state._players) do
            if player == localPlayer then
                return index
            end
        end

        return nil
    end

    local function tableContainsUuid(value, wantedUuid, depth, seen)
        depth = depth or 0
        seen = seen or {}

        if depth > 8 then
            return false
        end

        if type(value) ~= "table" then
            return false
        end

        if seen[value] then
            return false
        end

        seen[value] = true

        for key, child in pairs(value) do
            if tostring(key) == tostring(wantedUuid) then
                return true
            end

            if type(child) == "string" and child == tostring(wantedUuid) then
                return true
            end

            if type(child) == "table"
                and tableContainsUuid(child, wantedUuid, depth + 1, seen)
            then
                return true
            end
        end

        return false
    end

    local function isPetActuallyInTrade()
        local ok, state = pcall(function()
            return tradingCommands.GetState()
        end)

        if not ok or type(state) ~= "table" then
            return false
        end

        local botIndex = getBotTradeIndex(state)

        if botIndex == nil then
            return false
        end

        local items = state._items

        if type(items) ~= "table" then
            return false
        end

        local botItems = items[botIndex]

        if type(botItems) ~= "table" then
            return false
        end

        return tableContainsUuid(botItems, uuid, 0, {})
    end

    if isPetActuallyInTrade() then
        print(
            "[WITHDRAWAL] UUID already present in actual trade state; skipping duplicate SetItem | UUID=" ..
            tostring(uuid)
        )
        return true, "already_in_trade"
    end

    for attempt = 1, 3 do
        if attempt > 1 then
            task.wait(0.075)
        end

        if isPetActuallyInTrade() then
            print(
                "[WITHDRAWAL] UUID appeared in trade before retry; skipping SetItem | UUID=" ..
                tostring(uuid)
            )
            return true, "already_in_trade"
        end

        local ok, result = pcall(function()
            return tradingCommands.SetItem("Pet", uuid, 1)
        end)

        for verifyAttempt = 1, 12 do
            if isPetActuallyInTrade() then
                print(
                    "[WITHDRAWAL] SetItem verified in actual trade state | UUID=" ..
                    tostring(uuid) ..
                    " | return=" .. tostring(result)
                )
                return true, result
            end

            task.wait(0.05)
        end

        if not ok then
            lastErr = tostring(result)
        elseif result == false then
            lastErr = "SetItem returned false and pet was not present in trade state"
        else
            lastErr = "SetItem returned successfully but pet did not appear in trade state"
        end

        warn(
            "[WITHDRAWAL] SetItem attempt " ..
            tostring(attempt) ..
            "/3 failed for UUID " ..
            tostring(uuid) ..
            ": " ..
            tostring(lastErr)
        )
    end

    return false, lastErr or "Pet was not added to trade"
end

local function addGems(amount)
    pcall(function() tradingCommands.SetCurrency("Diamonds", amount) end)
end

-- ============================================================
-- READY / CONFIRMED DETECTION
-- ============================================================
local function isPlayerReady()
    local ready = false
    pcall(function()
        refreshTradeElements()
        local ok, state = pcall(function() return tradingCommands.GetState() end)
        if ok and state then
            for key, ps in pairs(state) do
                if type(ps) == "table" and tostring(key) ~= tostring(localPlayer.UserId) then
                    if ps.ready or ps.Ready or ps.confirmed or ps.Confirmed then ready = true; return end
                end
            end
            if type(state._ready) == "table" then
                for uid, v in pairs(state._ready) do
                    if v and tostring(uid) ~= tostring(localPlayer.UserId) then ready = true; return end
                end
            end
        end
        if theirItemsFrame then
            local btn = theirItemsFrame:FindFirstChild("Confirm")
            if btn and btn.Visible then ready = true; return end
            for _, c in pairs(theirItemsFrame:GetDescendants()) do
                if c.Visible then
                    if c:IsA("TextLabel") then
                        local t = c.Text:lower()
                        if t:find("ready") or t:find("waiting") then ready = true; return end
                    end
                    if c:IsA("ImageLabel") or c:IsA("ImageButton") then
                        local img = (c.Image or ""):lower()
                        if img:find("check") or img:find("tick") or img:find("ready") then ready = true; return end
                    end
                end
            end
        end
        if theirStatus and theirStatus.Visible then ready = true end
    end)
    return ready
end

local function isPlayerConfirmed()
    local confirmed = false
    pcall(function()
        refreshTradeElements()
        local ok, state = pcall(function() return tradingCommands.GetState() end)
        if ok and state then
            for uid, ps in pairs(state) do
                if type(ps) == "table" and (ps.confirmed or ps.Confirmed) and tostring(uid) ~= tostring(localPlayer.UserId) then
                    confirmed = true; return
                end
            end
        end
        if theirItemsFrame then
            local btn = theirItemsFrame:FindFirstChild("Confirm")
            if btn and not btn.Visible then confirmed = true; return end
        end
        if tradingFrame then
            for _, c in pairs(tradingFrame:GetDescendants()) do
                if c:IsA("TextLabel") and c.Visible then
                    local t = c.Text:lower()
                    if t:find("waiting for you") or t:find("your turn") then confirmed = true; return end
                end
            end
        end
    end)
    return confirmed
end

-- ============================================================
-- NAME LOOKUPS — must be defined before checkItems / checkBotTradeItems
-- ============================================================
local function getPetDefinition(nameList, assetId)
    for _, pd in next, nameList do
        if table.find(pd.assetIds, assetId) then return pd end
    end
    return nil
end

local function getName(nameList, assetId)
    local pd = getPetDefinition(nameList, assetId)
    return pd and pd.name or "???"
end

local function getTradeVariant(item, iconImage)
    local rarity = "normal"
    local shiny = false

    pcall(function()
        local iconObj = item:FindFirstChild("Icon") or item:FindFirstChildWhichIsA("ImageLabel")
        if iconObj and iconObj:FindFirstChild("RainbowGradient") then
            rarity = "rainbow"
        elseif table.find(goldAssetids, iconImage) then
            rarity = "golden"
        end
    end)

    pcall(function()
        shiny = item:FindFirstChild("ShinePulse") ~= nil
             or item:FindFirstChild("ShinyEffect") ~= nil
             or item:FindFirstChild("Shiny") ~= nil
    end)

    if shiny and rarity == "golden" then return "shiny_golden" end
    if shiny and rarity == "rainbow" then return "shiny_rainbow" end
    if shiny then return "shiny" end
    return rarity
end

local function getSupportedTradeIdentity(item, iconImage)
    local pd = getPetDefinition(nameAssetIds, iconImage)
    if not pd or not pd.configName then return nil, nil, nil end

    local variant = getTradeVariant(item, iconImage)
    local key = tostring(pd.configName) .. "|" .. variant
    local entry = catalogByKey[key]
    return entry, key, pd
end

local function getNameById(petId)
    local wantedId = tostring(petId or "")

    if wantedId == "" then
        return "???"
    end

    for _, pd in ipairs(nameAssetIds) do
        if tostring(pd.configName or "") == wantedId then
            return tostring(pd.name or "???")
        end
    end

    return "???"
end

-- ============================================================
-- COSMIC VALUE READER
-- Reads CV live from PS99's InfoOverlay tooltip, right before a deposit
-- is priced. This replaces the old single-shot reader.
--
-- Two real fixes vs. the version this file had before (2026-10-11):
--   1. Retries (up to 4 attempts with a short settle wait) instead of one
--      shot - a single hover+hope attempt missed the tooltip population
--      often enough in practice to matter for real deposits.
--   2. A plausibility floor against this pet's own known catalog value
--      (entry.value, already loaded in catalogByKey from /api/bots/pets) -
--      refuses to trust a read that's wildly below what this exact pet is
--      actually worth, which is what a stray OCR/text match on unrelated
--      small text elsewhere in the tooltip looks like. Held (nil) instead
--      of silently crediting a wrong, too-low price.
-- cvCache itself is still just a name->result table, but it's cleared in
-- resetTradeState() above now - every real trade starts with a clean
-- cache, so a price read for one deposit can never leak into a different,
-- later deposit of the same pet name.
-- ============================================================
local CV_PLAUSIBILITY_FLOOR = 0.1 -- a real read must be at least 10% of this pet's own catalog value
-- Copied verbatim from the proven thebot.lua (2026-10-11, operator
-- request: "copy the hovering thing") - this version ACTUALLY FORCES the
-- hover (moves the real cursor to the item slot + fires MouseEnter) before
-- reading the tooltip. The earlier version in this file only checked
-- whether InfoOverlay happened to already be populated, which it almost
-- never is without a real hover triggering it - that's why Cosmic Value
-- was effectively never read here. CV_INTER_ITEM_SETTLE_SECONDS gives
-- PS99's own tooltip handler a moment to close out after the PREVIOUS
-- item's hover before starting this one's, since a real cursor move
-- happening too fast after the last one can leave the tooltip stuck.
local CV_INTER_ITEM_SETTLE_SECONDS = 0.12

local function readCosmicValue(itemSlot, displayName, referenceValue)
    if cvCache[displayName] then return cvCache[displayName] end
    local refNum = tonumber(referenceValue)
    task.wait(CV_INTER_ITEM_SETTLE_SECONDS)

    local fire = getgenv and getgenv().firesignal or firesignal
    local moveMouse = (getgenv and (getgenv().mousemoveabs or getgenv().MouseMoveAbs))
        or mousemoveabs or MouseMoveAbs

    if type(fire) ~= "function" and type(moveMouse) ~= "function" then
        warn("[CV] Neither firesignal() nor mousemoveabs() is available in this executor - Cosmic Value cannot be read")
        return nil
    end

    local seenTitles = {}
    local allTextsSeen = {}
    local overlayFoundCount = 0
    for attempt = 1, 4 do
        print("[CV] Attempting read for " .. tostring(displayName) .. " (attempt " .. attempt .. "/4)")

        if type(moveMouse) == "function" then
            local ok = pcall(function()
                local inset = game:GetService("GuiService"):GetGuiInset()
                local pos = itemSlot.AbsolutePosition
                local size = itemSlot.AbsoluteSize
                local x = pos.X + size.X / 2 + inset.X
                local y = pos.Y + size.Y / 2 + inset.Y
                moveMouse(x, y)
            end)
            if not ok then
                warn("[CV] mousemoveabs failed for " .. tostring(displayName))
            end
        elseif attempt == 1 then
            warn("[CV] mousemoveabs() not available in this executor - relying on firesignal alone, which is known not to reliably populate the tooltip by itself")
        end

        if type(fire) == "function" then
            local ok, fireErr = pcall(function()
                fire(itemSlot.MouseMoved, 0, 0)
                fire(itemSlot.MouseEnter, 0, 0)
            end)
            if not ok then
                warn("[CV] firesignal(MouseEnter) threw for " .. tostring(displayName) .. ": " .. tostring(fireErr))
            end
        end

        task.wait(0.12)

        local overlay = playerGUI:FindFirstChild("InfoOverlay")
        if not overlay then
            warn("[CV] InfoOverlay not found in PlayerGui for " .. tostring(displayName) .. " (attempt " .. attempt .. "/4)")
        else
            overlayFoundCount = overlayFoundCount + 1
            local cvValue, demand, rejectedLow = nil, nil, nil

            for _, v in ipairs(overlay:GetDescendants()) do
                pcall(function()
                    if not (v:IsA("TextLabel") or v:IsA("TextButton")) then return end
                    local t = tostring(v.Text or "")
                    if t ~= "" and t ~= "..." and #allTextsSeen < 15 then
                        table.insert(allTextsSeen, v.Name .. "=\"" .. t .. "\"")
                    end
                    if t ~= "" and t ~= "..." and t:find("%(") and t:find("/10%)") then
                        if #seenTitles < 5 then table.insert(seenTitles, v.Name .. "=" .. t) end
                        local raw = t:match("^([%d%.]+[kmbt]?)")
                        local dem = t:match("%((%d+)/10%)")
                        if raw and not cvValue then
                            local num = tonumber(raw:match("^([%d%.]+)")) or 0
                            local suffix = (raw:match("[kmbt]$") or ""):lower()
                            local mult = { k = 1e3, m = 1e6, b = 1e9, t = 1e12 }
                            local parsed = math.floor(num * (mult[suffix] or 1))
                            if refNum and refNum > 0 and parsed < refNum * CV_PLAUSIBILITY_FLOOR then
                                rejectedLow = { parsed = parsed, refNum = refNum }
                            else
                                cvValue = parsed
                                demand = tonumber(dem)
                            end
                        end
                    end
                end)
            end

            if cvValue then
                if type(fire) == "function" then
                    pcall(function() fire(itemSlot.MouseLeave, 0, 0) end)
                end

                local result = { value = cvValue, demand = demand }
                cvCache[displayName] = result
                print("[CV] " .. tostring(displayName) .. " = " .. tostring(cvValue) .. " demand=" .. tostring(demand) .. " (attempt " .. attempt .. "/4)")
                return result
            end

            if rejectedLow then
                warn("[CV-REJECT] " .. tostring(displayName) .. ": read " .. tostring(rejectedLow.parsed) ..
                    " but catalog value is " .. tostring(rejectedLow.refNum) .. " - refusing as implausible (attempt " .. attempt .. "/4)")
            end
        end

        if attempt < 4 then
            task.wait(0.05)
        end
    end

    if type(fire) == "function" then
        pcall(function() fire(itemSlot.MouseLeave, 0, 0) end)
    end

    if overlayFoundCount == 0 then
        warn("[CV-FAIL] " .. tostring(displayName) .. ": InfoOverlay never appeared in PlayerGui on any of 4 attempts - the hover/tooltip trigger itself isn't opening it.")
    elseif #seenTitles > 0 then
        warn("[CV-FAIL] " .. tostring(displayName) .. ": InfoOverlay opened (" .. overlayFoundCount .. "/4 attempts) and had CV-shaped text, but every match got rejected as implausible or none parsed cleanly. Matches seen: " ..
            table.concat(seenTitles, " | "))
    elseif #allTextsSeen > 0 then
        warn("[CV-FAIL] " .. tostring(displayName) .. ": InfoOverlay opened (" .. overlayFoundCount .. "/4 attempts) but nothing inside matched the Cosmic Value shape at all. All text actually found inside: " .. table.concat(allTextsSeen, " | "))
    else
        warn("[CV-FAIL] " .. tostring(displayName) .. ": InfoOverlay opened (" .. overlayFoundCount .. "/4 attempts) but was completely empty of text.")
    end

    return nil
end

local function checkTheirItems()
    refreshTradeElements()
    if not theirItemsFrame then return {}, 0 end
    local itemsContainer = theirItemsFrame:FindFirstChild("Items")
    if not itemsContainer then
        task.wait()
        itemsContainer = theirItemsFrame:FindFirstChild("Items")
    end
    if not itemsContainer then return {}, 0 end
    local foundItems = {}
    for _, item in next, itemsContainer:GetChildren() do
        if item.Name ~= "ItemSlot" then continue end
        local iconImage = nil
        pcall(function()
            local d = item:FindFirstChild("Icon")
            if d and d:IsA("ImageLabel") then iconImage = d.Image end
            if not iconImage or iconImage == "" then
                for _, desc in next, item:GetDescendants() do
                    if desc:IsA("ImageLabel") and desc.Image ~= "" and desc.AbsoluteSize.X > 20 then
                        iconImage = desc.Image; break
                    end
                end
            end
        end)
        if not iconImage or iconImage == "" then continue end
        if not table.find(assetIds, iconImage) then continue end
        local name = getName(nameAssetIds, iconImage)
        local rarity = "Normal"
        pcall(function()
            local iconObj = item:FindFirstChild("Icon") or item:FindFirstChildWhichIsA("ImageLabel")
            if iconObj and iconObj:FindFirstChild("RainbowGradient") then rarity = "Rainbow"
            elseif table.find(goldAssetids, iconImage) then rarity = "Golden" end
        end)
        local shiny = false
        pcall(function()
            shiny = item:FindFirstChild("ShinePulse") ~= nil
                 or item:FindFirstChild("ShinyEffect") ~= nil
                 or item:FindFirstChild("Shiny") ~= nil
        end)
        local str = (shiny and "Shiny " or "") .. (rarity ~= "Normal" and (rarity .. " ") or "") .. name
        if table.find(supporteditems, str) then
            local cv = readCosmicValue(item, str, nil)
            table.insert(foundItems, {
                name = str,
                cosmicValue = cv and cv.value or nil,
                demand = cv and cv.demand or nil,
            })
        end
    end
    return foundItems, client_their_gems()
end

-- ============================================================
-- READ BOT'S OWN SIDE OF TRADE (what the bot actually sent)
-- ============================================================
local function checkBotTradeItems()
    local itemsContainer = nil

    for attempt = 1, 8 do
        itemsContainer = findBotTradeItemsContainer()
        if itemsContainer then break end
        if attempt < 8 then task.wait(0.025) end
    end

    if not itemsContainer then
        warn("[BOT-SIDE] Could not locate the bot's trade Items container")
        return {}, 0
    end

    local foundItems = {}
    for _, item in ipairs(itemsContainer:GetChildren()) do
        if item.Name ~= "ItemSlot" then continue end

        local iconImage = nil
        pcall(function()
            local d = item:FindFirstChild("Icon")
            if d and d:IsA("ImageLabel") then iconImage = d.Image end
            if not iconImage or iconImage == "" then
                for _, desc in ipairs(item:GetDescendants()) do
                    if desc:IsA("ImageLabel") and desc.Image ~= "" and desc.AbsoluteSize.X > 20 then
                        iconImage = desc.Image
                        break
                    end
                end
            end
        end)

        if not iconImage or iconImage == "" then continue end
        if not table.find(assetIds, iconImage) then continue end

        local name = getName(nameAssetIds, iconImage)
        local rarity = "Normal"
        pcall(function()
            local iconObj = item:FindFirstChild("Icon") or item:FindFirstChildWhichIsA("ImageLabel")
            if iconObj and iconObj:FindFirstChild("RainbowGradient") then
                rarity = "Rainbow"
            elseif table.find(goldAssetids, iconImage) then
                rarity = "Golden"
            end
        end)

        local shiny = false
        pcall(function()
            shiny = item:FindFirstChild("ShinePulse") ~= nil
                or item:FindFirstChild("ShinyEffect") ~= nil
                or item:FindFirstChild("Shiny") ~= nil
        end)

        local str = (shiny and "Shiny " or "") .. (rarity ~= "Normal" and (rarity .. " ") or "") .. name
        print("[BOT-SIDE] Detected: " .. str)
        table.insert(foundItems, str)
    end

    local gemsInTrade = lastBotGemsAdded
    print("[BOT-SIDE] Read " .. #foundItems .. " pets + " .. gemsInTrade .. " gems from bot's trade side")
    return foundItems, gemsInTrade
end

-- ============================================================
-- WITHDRAWAL TRADE-SIDE VERIFICATION
-- ============================================================
local function normalizePetDisplayName(value)
    local text = tostring(value or ""):lower()
    text = text:gsub("ñ", "n")
    text = text:gsub("%s+", " ")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
    return text
end

local function countMatchingPetNames(list, target)
    local wanted = normalizePetDisplayName(target)
    local count = 0
    for _, name in ipairs(list or {}) do
        if normalizePetDisplayName(name) == wanted then
            count = count + 1
        end
    end
    return count
end

local function verifyWithdrawalPetAdded(expectedName, beforePlayerPets, beforeTheirPets)
    local beforeA = beforePlayerPets or {}
    local beforeB = beforeTheirPets or {}
    local beforeCount = countMatchingPetNames(beforeA, expectedName) + countMatchingPetNames(beforeB, expectedName)
    local sawAnyTradePet = false
    local lastA, lastB = beforeA, beforeB

    for attempt = 1, 6 do
        if attempt > 1 then
            task.wait(0.035)
        end

        local afterA, afterB = getTradeSides()
        lastA, lastB = afterA, afterB

        if (#afterA + #afterB) > 0 then
            sawAnyTradePet = true
        end

        local afterCount = countMatchingPetNames(afterA, expectedName) + countMatchingPetNames(afterB, expectedName)

        if afterCount > beforeCount then
            print("[WITHDRAWAL-VERIFY] OK: actual trade contains " .. tostring(expectedName))
            return true, afterA, afterB, "verified"
        end
    end

    if not sawAnyTradePet and beforeCount == 0 then
    warn(
        "[WITHDRAWAL-VERIFY] Could not verify '" ..
        tostring(expectedName) ..
        "' in trade UI/state"
    )

    return false, lastA, lastB, "unverified"
end

    warn("[WITHDRAWAL-VERIFY] MISMATCH: expected '" .. tostring(expectedName) .. "' | " .. describeTradeSides(lastA, lastB))
    return false, lastA, lastB, "mismatch"
end
-- ============================================================
-- ITEM LOADING (startup)
-- ============================================================
makeCatalogDisplay = function(entry)
    if type(entry) ~= "table" or not entry.name then return nil end
    local variant = tostring(entry.variant or "normal"):lower()
    local prefix = ""
    if variant == "shiny_golden" then
        prefix = "Shiny Golden "
    elseif variant == "shiny_rainbow" then
        prefix = "Shiny Rainbow "
    elseif variant == "shiny" then
        prefix = "Shiny "
    elseif variant == "golden" then
        prefix = "Golden "
    elseif variant == "rainbow" then
        prefix = "Rainbow "
    end
    return prefix .. tostring(entry.name)
end

local buildEnchantCatalog

local function GetSupported()
   print("[ITEMS] Fetching live pet catalog from /api/bots/pets...")
local success, response = makeGetRequest("/api/bots/pets")
    if not success or not response or response.StatusCode ~= 200 then
        print("[ITEMS] Failed - status: " .. tostring(response and response.StatusCode or "nil"))
        if response and response.Body then print("[ITEMS] Body: " .. response.Body:sub(1, 500)) end
        return false
    end

    local data = decodeBody(response)
    if not data then print("[ITEMS] Could not decode /pets response"); return false end

    local list = data.pets
    if type(list) ~= "table" or #list == 0 then
        print("[ITEMS] /pets returned no pets")
        return false
    end

    supporteditems = {}
    catalogByDisplay = {}
    catalogByKey = {}
    catalogByIdentity = {}

    for _, entry in ipairs(list) do
        if type(entry) == "table" and entry.configName and entry.name then
            local variant = tostring(entry.variant or "normal"):lower()
            local configName = tostring(entry.configName)
            local key = configName .. "|" .. variant
            local display = makeCatalogDisplay(entry)

            if display then
                table.insert(supporteditems, display)

                if catalogByDisplay[display] == nil then
                    catalogByDisplay[display] = entry
                else
                    catalogByDisplay[display] = nil
                end

                catalogByKey[key] = entry
                catalogByIdentity[key] = entry
            end
        end
    end

    print("[ITEMS] [OK] " .. #supporteditems .. " live catalog entries loaded")
    print("[ITEMS] Catalog identity: configName + variant (case-sensitive)")
    print("[ITEMS] Accepted tiers block: " .. tostring(data.acceptedTiers and "present" or "missing"))

    buildEnchantCatalog()

    return next(catalogByKey) ~= nil
end

-- ============================================================
-- ENCHANT CATALOG FALLBACK
-- ============================================================

local enchantByName = {}

local function normalizeCatalogText(value)
    return tostring(value or "")
        :lower()
        :gsub("ñ", "n")
        :gsub("%s+", " ")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
end

buildEnchantCatalog = function()
    enchantByName = {}

    for key, entry in pairs(catalogByKey) do
        if type(entry) == "table"
            and tostring(entry.category or ""):lower() == "enchant"
            and tostring(entry.variant or "normal"):lower() == "normal"
        then
            local name = normalizeCatalogText(entry.name)

            if name ~= "" then
                if enchantByName[name] == nil then
                    enchantByName[name] = {
                        entry = entry,
                        key = key,
                    }
                else
                    enchantByName[name] = false
                end
            end
        end
    end

    local count = 0
    for _, value in pairs(enchantByName) do
        if value then
            count = count + 1
        end
    end

    print("[ENCHANTS] Loaded " .. tostring(count) .. " unique enchant display names")
end

local function getItemDisplayText(item)
    local texts = {}

    pcall(function()
        for _, desc in ipairs(item:GetDescendants()) do
            if desc:IsA("TextLabel")
                or desc:IsA("TextButton")
                or desc:IsA("TextBox")
            then
                local text = normalizeCatalogText(desc.Text)

                if text ~= "" then
                    table.insert(texts, text)
                end
            end
        end
    end)

    return texts
end

local enchantIdentityCache = setmetatable({}, { __mode = "k" })

local function getSupportedEnchantIdentity(item)
    if not item then return nil, nil end

    local cached = enchantIdentityCache[item]
    if cached then
        if cached.entry then
            return cached.entry, cached.key
        end
        return nil, nil
    end

    local texts = getItemDisplayText(item)

    for _, text in ipairs(texts) do
        local match = enchantByName[text]

        if match and match.entry then
            enchantIdentityCache[item] = {
                entry = match.entry,
                key = match.key,
            }
            return match.entry, match.key
        end
    end

    enchantIdentityCache[item] = {
        entry = false,
        key = false,
    }

    return nil, nil
end

local registeredPetIds = {}

local function registerPetDefinition(pd, isHugeOrTitanic)
    if type(pd) ~= "table" or not pd._id or not pd.name then return end

    local configName = tostring(pd._id)
    if registeredPetIds[configName] then
        if isHugeOrTitanic and not table.find(hugesTitanicsIds, configName) then
            table.insert(hugesTitanicsIds, configName)
        end
        return
    end
    registeredPetIds[configName] = true

    local petAssets = {}
    if pd.thumbnail and pd.thumbnail ~= "" then
        table.insert(assetIds, pd.thumbnail)
        table.insert(petAssets, pd.thumbnail)
    end
    if pd.goldenThumbnail and pd.goldenThumbnail ~= "" then
        table.insert(assetIds, pd.goldenThumbnail)
        table.insert(goldAssetids, pd.goldenThumbnail)
        table.insert(petAssets, pd.goldenThumbnail)
    end

    table.insert(nameAssetIds, {
        name = tostring(pd.name),
        configName = configName,
        assetIds = petAssets,
    })

    if isHugeOrTitanic then
        table.insert(hugesTitanicsIds, configName)
    end
end

local petsDirectory = replicatedStorage:FindFirstChild("__DIRECTORY")
    and replicatedStorage.__DIRECTORY:FindFirstChild("Pets")

if petsDirectory then
    for _, petModule in ipairs(petsDirectory:GetDescendants()) do
        if petModule:IsA("ModuleScript") then
            local ok, pd = pcall(require, petModule)
            if ok and pd then
                local isHugeOrTitanic =
                    petModule:IsDescendantOf(replicatedStorage.__DIRECTORY.Pets.Huge)
                    or petModule:IsDescendantOf(replicatedStorage.__DIRECTORY.Pets.Titanic)
                    or (replicatedStorage.__DIRECTORY.Pets:FindFirstChild("Gargantuan")
                        and petModule:IsDescendantOf(replicatedStorage.__DIRECTORY.Pets.Gargantuan))
                registerPetDefinition(pd, isHugeOrTitanic)
            end
        end
    end
end

print("[ITEMS] Registered " .. #nameAssetIds .. " PS99 pet definitions for icon matching")

pcall(function()
    local g = replicatedStorage.__DIRECTORY.Pets:FindFirstChild("Gargantuan")
    print("[ITEMS] Gargantuan directory: " .. (g and "present" or "absent"))
end)

-- ============================================================
-- GEM PARSING / READING
-- ============================================================
local function client_trade_gems()
    local gems = 0

    local ok, err = pcall(function()
        refreshTradeElements()

        local state = tradingCommands.GetState()
        if type(state) ~= "table" then
            warn("[GEMS] GetState() returned invalid state")
            return
        end

        local items = state._items
        local players = state._players

        if type(items) ~= "table" then
            warn("[GEMS] Trade state has no _items table")
            return
        end

        local otherIndex = nil

        if type(players) == "table" then
            for index, player in pairs(players) do
                if player ~= localPlayer then
                    otherIndex = index
                    break
                end
            end
        end

        if otherIndex == nil then
            for index in pairs(items) do
                otherIndex = index
                break
            end
        end

        if otherIndex == nil then
            warn("[GEMS] Could not determine other player's trade index")
            return
        end

        local otherItems = items[otherIndex]

        if type(otherItems) ~= "table" then
            warn("[GEMS] No trade items for player index " .. tostring(otherIndex))
            return
        end

        local currency = otherItems.Currency

        if type(currency) ~= "table" then
            print("[GEMS] Other player has no Currency table")
            return
        end

        for uid, entry in pairs(currency) do
            if type(entry) == "table"
                and type(entry._data) == "table"
                and tostring(entry._data.id) == "Diamonds"
            then
                local amount = tonumber(entry._data._am)

                if amount then
                    gems = math.max(0, math.floor(amount))
                    print(
                        "[GEMS] Found Diamonds in trade state | " ..
                        "uid=" .. tostring(uid) ..
                        " | amount=" .. tostring(gems)
                    )
                    break
                end
            end
        end

        print("[GEMS] Player offered Diamonds: " .. tostring(gems))
    end)

    if not ok then
        warn("[GEMS] Trade-state reader error: " .. tostring(err))
    end

    return gems
end

local function client_their_gems()
    return client_trade_gems()
end

-- ============================================================
-- ITEM VALIDATION (checks the user's deposit side of the trade)
-- isWithdrawal: pass true so that having NO deposit items is not treated as an error
--
-- REAL FIX (2026-10-11): this is the actual function the live deposit flow
-- calls (connectStatus -> checkItems). It used to store each found item as
-- a plain identityKey string with no Cosmic Value at all - readCosmicValue
-- was never called from here, only from checkTheirItems, which the real
-- deposit flow never uses. Items are now built as {name=identityKey,
-- cosmicValue=.., demand=..} tables, same shape processDeposit already
-- knows how to read - CV reading is now part of every real deposit, not
-- just the unused side path.
-- ============================================================
local function checkItems(isWithdrawal)
    isWithdrawal = isWithdrawal == true
    refreshTradeElements()
    local itemsContainer
    for _ = 1, 8 do
        if playerItemsFrame then
            itemsContainer = playerItemsFrame:FindFirstChild("Items")
            if itemsContainer then break end
        else
            refreshTradeElements()
        end
        task.wait(0.025)
    end
    if not itemsContainer then
        print("[CHECK] Trade window not ready - itemsContainer nil")
        if isWithdrawal then return false, {} end
        return true, "Trade window not ready"
    end

    local foundItems, itemTotal, unsupported = {}, 0, {}

    for _, item in next, itemsContainer:GetChildren() do
        if item.Name ~= "ItemSlot" then continue end

        itemTotal = itemTotal + 1

        local iconImage = nil
        pcall(function()
            local directIcon = item:FindFirstChild("Icon")
            if directIcon and directIcon:IsA("ImageLabel") then
                iconImage = directIcon.Image
            end
            if not iconImage or iconImage == "" then
                for _, desc in next, item:GetDescendants() do
                    if desc:IsA("ImageLabel") and desc.Image and desc.Image ~= "" then
                        if desc.AbsoluteSize.X > 20 then
                            iconImage = desc.Image
                            break
                        end
                    end
                end
            end
        end)

        if not iconImage or iconImage == "" then
            print("[CHECK] ItemSlot #" .. itemTotal .. " has no readable icon - skipping")
            continue
        end

        print("[CHECK] Slot #" .. itemTotal .. " icon: " .. iconImage)

        local entry, identityKey, pd = getSupportedTradeIdentity(item, iconImage)
        local variant = getTradeVariant(item, iconImage)

        local displayName

        if pd then
            displayName = makeCatalogDisplay({
                name = pd.name,
                variant = variant
            })
        else
            displayName = getName(nameAssetIds, iconImage)
        end

        if not entry then
            local enchantEntry, enchantKey = getSupportedEnchantIdentity(item)

            if enchantEntry then
                entry = enchantEntry
                identityKey = enchantKey
                displayName = tostring(enchantEntry.name)

                print(
                    "[CHECK] Identified Enchant: " ..
                    displayName ..
                    " [" ..
                    tostring(identityKey) ..
                    "]"
                )
            end
        end

        if not entry then
            print(
                "[CHECK] Unsupported/unmapped item identity: " ..
                tostring(identityKey or displayName)
            )

            table.insert(
                unsupported,
                displayName ~= "" and displayName or "Unknown item"
            )
        else
            print(
                "[CHECK] Identified: " ..
                tostring(displayName) ..
                " [" ..
                tostring(identityKey) ..
                "]"
            )

            -- Read Cosmic Value for Huge/Titanic/Gargantuan pets only -
            -- those are the only tier this ever needs a real price for.
            -- entry.value is this pet's own last-known catalog price, used
            -- as the plausibility floor's reference point (see
            -- readCosmicValue's own doc comment).
            --
            -- IMPORTANT: this must check the pet's BASE name (pd.name /
            -- entry.name), NOT displayName - displayName has the variant
            -- word prepended in front ("Rainbow Huge X", "Shiny Huge Y"),
            -- so a prefix check against displayName silently fails for
            -- every non-normal variant and skips CV entirely for them.
            -- Confirmed live: a Rainbow Huge Pixel Griffin and a Shiny
            -- Huge Atlantean Dolphin both got credited at 0 while a
            -- normal-variant Huge pet in the same deposit worked fine -
            -- this was why.
            local baseName = tostring((pd and pd.name) or (entry and entry.name) or displayName or "")
            local lname = baseName:lower()
            local isAcceptedTier = lname:sub(1, 5) == "huge "
                or lname:sub(1, 8) == "titanic "
                or lname:sub(1, 11) == "gargantuan "

            local cosmicValue, demand = nil, nil
            if isAcceptedTier then
                local cv = readCosmicValue(item, displayName, entry and entry.value)
                if cv then
                    cosmicValue = cv.value
                    demand = cv.demand
                end
            end

            table.insert(foundItems, {
                name = identityKey,
                displayName = displayName,
                isAcceptedTier = isAcceptedTier,
                cosmicValue = cosmicValue,
                demand = demand,
            })
        end
    end

    print("[CHECK] itemTotal=" .. itemTotal .. " found=" .. #foundItems .. " unsupported=" .. #unsupported)

    if itemTotal == 0 then
        if isWithdrawal then
            print("[CHECK] Withdrawal mode: user added no deposit items - proceeding")
            return false, foundItems
        end
        local gems = client_trade_gems()
        if gems > 0 then
            print("[CHECK] No pets but gems=" .. gems .. " - accepting gem-only deposit")
            return false, foundItems
        end
        return true, "Add pets or gems to trade"
    end

    if #foundItems == 0 and itemTotal > 0 then
        print("[CHECK] Had " .. itemTotal .. " slots but no supported pet identities were found")
        return true, "Unsupported pet - not in live BloxyFlip catalog"
    end

    if #unsupported > 0 then
        return true, "Unsupported: " .. table.concat(unsupported, ", ")
    end

    return false, foundItems
end

-- ============================================================
-- WITHDRAWAL ITEMS
-- ============================================================
local function withdrawalReadField(pet, ...)
    if type(pet) ~= "table" then
        return nil
    end

    local fields = {...}

    for _, field in ipairs(fields) do
        local value = pet[field]
        if value ~= nil then
            return value
        end
    end

    for _, containerName in ipairs({"_data", "data"}) do
        local container = pet[containerName]
        if type(container) == "table" then
            for _, field in ipairs(fields) do
                local value = container[field]
                if value ~= nil then
                    return value
                end
            end
        end
    end

    return nil
end

local function withdrawalPetId(pet)
    local value = withdrawalReadField(
        pet,
        "id",
        "_id",
        "configName",
        "petId",
        "petConfigId",
        "config",
        "name"
    )

    return value ~= nil and tostring(value) or ""
end

local function withdrawalPetName(pet, petId)
    local explicitName = withdrawalReadField(pet, "name", "petName", "displayName")
    if explicitName ~= nil and tostring(explicitName) ~= "" then
        return tostring(explicitName)
    end

    if petId and tostring(petId) ~= "" then
        return tostring(getNameById(petId))
    end

    return "???"
end

local function withdrawalPetVariant(pet)
    local explicit = withdrawalReadField(pet, "variant", "rarity", "type")

    if type(explicit) == "string" then
        local v = explicit:lower()
        if v == "gold" then v = "golden" end
        if v == "rb" then v = "rainbow" end
        if v == "rainbow" then
            explicit = "rainbow"
        elseif v == "golden" or v == "gold" then
            explicit = "golden"
        elseif v == "shiny_golden" then
            explicit = "shiny_golden"
        elseif v == "shiny_rainbow" then
            explicit = "shiny_rainbow"
        elseif v == "shiny" then
            explicit = "shiny"
        end
    end

    -- PS99's real save record uses `sh` for shiny, not `shiny`/`isShiny` -
    -- checked first since it's the field actually confirmed live; the
    -- others kept as harmless fallbacks.
    local shiny = withdrawalReadField(pet, "sh", "shiny", "isShiny")
    local shinyBool = shiny == true
        or tonumber(shiny) == 1
        or (type(shiny) == "string" and shiny:lower() == "true")

    local pt = withdrawalReadField(pet, "pt", "petType", "PetType", "variantType")

    local baseVariant = nil

    if type(explicit) == "string" then
        local v = explicit:lower()
        if v == "rainbow" or v == "golden" then
            baseVariant = v
        end
    end

    if baseVariant == nil then
        local n = tonumber(pt)
        if n == 2 then
            baseVariant = "rainbow"
        elseif n == 1 then
            baseVariant = "golden"
        end
    end

    if shinyBool and baseVariant == "golden" then
        return "shiny_golden"
    end
    if shinyBool and baseVariant == "rainbow" then
        return "shiny_rainbow"
    end
    if shinyBool then
        return "shiny"
    end

    return baseVariant or "normal"
end

local function normalizeWithdrawalInventoryText(v)
    return tostring(v or "")
        :lower()
        :gsub("ñ", "n")
        :gsub("%s+", " ")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
end

local function getHugesTitanics(requestedItems)
    local saveData = nil

    if type(saveModule) == "table" then
        local getters = {
            function() return saveModule.Get() end,
            function() return saveModule:Get() end,
            function() return saveModule.GetData() end,
            function() return saveModule:GetData() end,
            function() return saveModule.Data end,
            function() return saveModule.SaveData end,
            function() return saveModule.PlayerData end,
        }

        for _, getter in ipairs(getters) do
            local ok, result = pcall(getter)
            if ok and type(result) == "table" then
                saveData = result
                break
            end
        end
    end

    local inventoryPets = saveData
        and saveData.Inventory
        and saveData.Inventory.Pet

    local results = {}
    local seen = {}

    print("[WITHDRAWAL-DIAG] LIVE INVENTORY SOURCE = saveModule -> Inventory.Pet")

    if type(inventoryPets) ~= "table" then
        warn("[WITHDRAWAL-DIAG] Inventory.Pet unavailable | saveDataType=" ..
            tostring(type(saveData)) ..
            " | InventoryType=" ..
            tostring(saveData and type(saveData.Inventory) or "nil") ..
            " | PetType=" ..
            tostring(saveData and saveData.Inventory and type(saveData.Inventory.Pet) or "nil"))
        return results
    end

    local function addInventoryPet(uuid, pet)
        if uuid == nil or pet == nil then
            return
        end

        local uuidStr = tostring(uuid)
        if uuidStr == "" or seen[uuidStr] then
            return
        end

        local petId = withdrawalPetId(pet)
        local name = withdrawalPetName(pet, petId)
        local variant = withdrawalPetVariant(pet)

        local idNorm = normalizeWithdrawalInventoryText(petId)
        local nameNorm = normalizeWithdrawalInventoryText(name)

        local isHuge = idNorm:find("huge", 1, true) ~= nil
            or nameNorm:find("huge", 1, true) ~= nil

        local isTitanic = idNorm:find("titanic", 1, true) ~= nil
            or nameNorm:find("titanic", 1, true) ~= nil

        local isGargantuan = idNorm:find("gargantuan", 1, true) ~= nil
            or nameNorm:find("gargantuan", 1, true) ~= nil

        local isExplicitlyRequested = false

        if type(requestedItems) == "table" then
            for _, req in ipairs(requestedItems) do
                local reqId = normalizeWithdrawalInventoryText(
                    req.petId or req.configName
                )
                local reqName = normalizeWithdrawalInventoryText(req.petName)

                if reqName == "" and reqId ~= "" then
                    local entry = catalogByKey[
                        tostring(req.petId or req.configName)
                            .. "|"
                            .. tostring(req.variant or "normal"):lower()
                    ]
                    if entry and entry.name then
                        reqName = normalizeWithdrawalInventoryText(entry.name)
                    end
                end

                if (reqId ~= "" and idNorm == reqId)
                    or (reqName ~= "" and nameNorm == reqName)
                then
                    isExplicitlyRequested = true
                    break
                end
            end
        end

        if isHuge or isTitanic or isGargantuan or isExplicitlyRequested then
            seen[uuidStr] = true

            table.insert(results, {
                uuid = uuidStr,
                id = petId,
                name = name,
                variant = variant,
                pet = pet,
                source = "saveData.Inventory.Pet",
            })
        end
    end

    for uuid, pet in pairs(inventoryPets) do
        if type(pet) == "table" then
            addInventoryPet(uuid, pet)
        end
    end

    print(string.format(
        "[WITHDRAWAL] Inventory-only scan found %d candidate pets (high-value + explicitly requested)",
        #results
    ))

    return results
end

local function getBotGemBalance()
    local balance = 0

    local ok, err = pcall(function()
        local leaderstats = localPlayer:FindFirstChild("leaderstats")

        if not leaderstats then
            warn("[GEM-BALANCE] leaderstats not found")
            return
        end

        local diamonds = leaderstats:FindFirstChild("Diamonds")

        if not diamonds then
            for _, child in ipairs(leaderstats:GetChildren()) do
                if (child:IsA("IntValue") or child:IsA("NumberValue"))
                    and child.Name:lower():find("diamond")
                then
                    diamonds = child
                    break
                end
            end
        end

        if not diamonds then
            warn("[GEM-BALANCE] Diamonds leaderstat not found")
            return
        end

        balance = tonumber(diamonds.Value) or 0

        print(
            "[GEM-BALANCE] Using in-game leaderstats.Diamonds: "
            .. tostring(balance)
        )
    end)

    if not ok then
        warn("[GEM-BALANCE] Failed reading Diamonds leaderstat: " .. tostring(err))
        return 0
    end

    return math.max(0, math.floor(balance))
end

local function withdrawalDisplayFromRequest(req)
    local petId = tostring(req.petId or req.configName or "")
    local variant = tostring(req.variant or "normal")
    local entry = catalogByKey[petId .. "|" .. variant]
    if entry then return makeCatalogDisplay(entry) end
    if req.petName then
        local prefix = ""
        local v = variant:lower()
        if v == "shiny_golden" then prefix = "Shiny Golden "
        elseif v == "shiny_rainbow" then prefix = "Shiny Rainbow "
        elseif v == "shiny" then prefix = "Shiny "
        elseif v == "golden" then prefix = "Golden "
        elseif v == "rainbow" then prefix = "Rainbow " end
        return prefix .. tostring(req.petName)
    end
    return nil
end

local function getStableWithdrawalInventory(requestedItems)
    local lastSignature = nil
    local stableCount = 0
    local latest = {}

    local function signature(list)
        local ids = {}
        for _, pet in ipairs(list or {}) do
            ids[#ids + 1] = table.concat({
                tostring(pet.uuid or ""),
                tostring(pet.id or ""),
                tostring(pet.type or ""),
                tostring(pet.shiny and 1 or 0),
            }, "|")
        end
        table.sort(ids)
        return table.concat(ids, "\n")
    end

    local function normalize(v)
        return tostring(v or ""):lower():gsub("ñ", "n"):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    end

    local function requestTargetsPresent(list)
        if type(requestedItems) ~= "table" or #requestedItems == 0 then
            return true
        end

        for _, req in ipairs(requestedItems) do
            local requestedId = normalize(req.petId or req.configName)
            local requestedName = normalize(req.petName)
            local requestedVariant = normalize(req.variant or "normal")
            if requestedVariant == "gold" then requestedVariant = "golden" end
            if requestedVariant == "rb" then requestedVariant = "rainbow" end

            if requestedName == "" and requestedId ~= "" then
                local entry = catalogByKey[
                    tostring(req.petId or req.configName)
                        .. "|"
                        .. requestedVariant
                ]
                if entry and entry.name then
                    requestedName = normalize(entry.name)
                end
            end

            local quantity = math.max(1, tonumber(req.quantity or 1) or 1)
            local found = 0

            for _, pet in ipairs(list) do
                local petVariant = normalize(tostring(pet.variant or "normal"))
                local petName = normalize(pet.name or getNameById(pet.id))
                local petId = normalize(pet.id)

                local idMatch =
                    requestedId ~= "" and petId == requestedId

                local nameMatch =
                    requestedName ~= "" and petName == requestedName

                if (idMatch or nameMatch)
                    and petVariant == requestedVariant
                then
                    found = found + 1
                    if found >= quantity then
                        break
                    end
                end
            end

            if found < quantity then
                return false
            end
        end

        return true
    end

    local MAX_ATTEMPTS = 3
    for attempt = 1, MAX_ATTEMPTS do
        latest = getHugesTitanics(requestedItems)

        local sig = signature(latest)
        if sig == lastSignature then
            stableCount = stableCount + 1
        else
            stableCount = 1
            lastSignature = sig
        end

        local targetsPresent = requestTargetsPresent(latest)

        print("[WITHDRAWAL-INVENTORY] Snapshot " .. tostring(attempt) ..
            "/" .. tostring(MAX_ATTEMPTS) ..
            " | pets=" .. tostring(#latest) ..
            " | stable=" .. tostring(stableCount) .. "/2" ..
            " | requestedPresent=" .. tostring(targetsPresent))

        if targetsPresent then
            print("[WITHDRAWAL-INVENTORY] Requested items found in live inventory; proceeding immediately")
            return latest
        end

        if stableCount >= 2 then
            print("[WITHDRAWAL-INVENTORY] Inventory stabilized; requested item still not found")
            return latest
        end

        if attempt < MAX_ATTEMPTS then
            task.wait(0.10)
        end
    end

    print("[WITHDRAWAL-INVENTORY] Using latest snapshot after fast sync window")
    return latest
end

local function addWithdrawalItems(withdrawalData)
    if not withdrawalData then
        return {}, 0, false, "Missing withdrawal data"
    end

    local MAX_TRADE_PETS = 100

    local itemsGiven = {}
    local missingPets = {}
    local requestedItems = withdrawalData.items or {}
    local gemsRequested = tonumber(withdrawalData.gems) or 0

    print("[WITHDRAWAL-DIAG] PREP REQUEST | items=" ..
        tostring(#requestedItems) ..
        " | gems=" ..
        tostring(gemsRequested))

    for i, req in ipairs(requestedItems) do
        if i > 10 then
            print("[WITHDRAWAL-DIAG] PREP REQUEST | more than 10 requested entries; truncated")
            break
        end
        print("[WITHDRAWAL-DIAG] REQUEST[" .. tostring(i) ..
            "] petId=" .. tostring(req.petId) ..
            " | petName=" .. tostring(req.petName) ..
            " | variant=" .. tostring(req.variant) ..
            " | quantity=" .. tostring(req.quantity))
    end

    local botHuges = getStableWithdrawalInventory(requestedItems)
    local usedUUIDs = {}

    local function normalizeText(v)
        local text = tostring(v or ""):lower()
        text = text:gsub("ñ", "n")
        return text
            :gsub("%s+", " ")
            :gsub("^%s+", "")
            :gsub("%s+$", "")
    end

    local function getBotVariant(b)
        if b.shiny and b.type == "Golden" then
            return "shiny_golden"
        end

        if b.shiny and b.type == "Rainbow" then
            return "shiny_rainbow"
        end

        if b.shiny then
            return "shiny"
        end

        if b.type == "Golden" then
            return "golden"
        end

        if b.type == "Rainbow" then
            return "rainbow"
        end

        return "normal"
    end

    local function petMatches(b, req, displayName, requestedVariant)
        local botVariant = tostring(b.variant or getBotVariant(b) or "normal"):lower()

        if botVariant == "gold" then botVariant = "golden" end
        if botVariant == "rb" then botVariant = "rainbow" end

        if botVariant ~= requestedVariant then
            return false
        end

        local requestedId = normalizeText(
            req.petId or req.configName
        )

        local botId = normalizeText(b.id)

        local botName = normalizeText(
            b.name
                or getNameById(b.id)
        )

        local expectedName = normalizeText(req.petName or "")

        if expectedName == "" and requestedId ~= "" then
            local entry = catalogByKey[
                tostring(req.petId or req.configName)
                    .. "|"
                    .. requestedVariant
            ]

            if entry and entry.name then
                expectedName = normalizeText(entry.name)
            end
        end

        if requestedId ~= "" and botId == requestedId then
            return true
        end

        if expectedName ~= ""
            and botName ~= ""
            and botName ~= "???"
            and botName == expectedName
        then
            return true
        end

        return false
    end

    local petLimitReached = false

    for reqIndex, req in ipairs(requestedItems) do
        local petId = tostring(
            req.petId
                or req.configName
                or ""
        )

        local requestedVariant =
            tostring(req.variant or "normal"):lower()
        if requestedVariant == "gold" then requestedVariant = "golden" end
        if requestedVariant == "rb" then requestedVariant = "rainbow" end

        local quantity =
            math.max(
                1,
                tonumber(req.quantity or 1) or 1
            )

        local displayName =
            withdrawalDisplayFromRequest(req)
            or tostring(req.petName or petId)

        for quantityIndex = 1, quantity do

            if #itemsGiven >= MAX_TRADE_PETS then
                petLimitReached = true

                local remainingCurrent =
                    quantity - quantityIndex + 1

                for _ = 1, remainingCurrent do
                    table.insert(
                        missingPets,
                        tostring(displayName)
                    )
                end

                for remainingReqIndex =
                    reqIndex + 1,
                    #requestedItems
                do
                    local remainingReq =
                        requestedItems[remainingReqIndex]

                    local remainingName =
                        withdrawalDisplayFromRequest(
                            remainingReq
                        )
                        or tostring(
                            remainingReq.petName
                                or remainingReq.petId
                                or remainingReq.configName
                                or "Unknown pet"
                        )

                    local remainingQuantity =
                        math.max(
                            1,
                            tonumber(
                                remainingReq.quantity or 1
                            ) or 1
                        )

                    for _ = 1, remainingQuantity do
                        table.insert(
                            missingPets,
                            tostring(remainingName)
                        )
                    end
                end

                print(
                    "[WITHDRAWAL] Trade limit reached at " ..
                    tostring(MAX_TRADE_PETS) ..
                    " pets - remaining pets stay pending"
                )

                break
            end

            local found = false
            local matchingCandidatesTried = 0

            local debugMatches = 0
            for _, dbgPet in ipairs(botHuges) do
                if petMatches(dbgPet, req, displayName, requestedVariant) then
                    debugMatches = debugMatches + 1
                    if debugMatches <= 3 then
                        print("[WITHDRAWAL-DIAG] MATCHABLE INVENTORY PET #" ..
                            tostring(debugMatches) ..
                            " | name=" .. tostring(dbgPet.name or getNameById(dbgPet.id)) ..
                            " | id=" .. tostring(dbgPet.id) ..
                            " | variant=" .. tostring(dbgPet.variant) ..
                            " | uuid=" .. tostring(dbgPet.uuid) ..
                            " | source=" .. tostring(dbgPet.source))
                    end
                end
            end
            print("[WITHDRAWAL-DIAG] Requested '" .. tostring(displayName) ..
                "' | variant=" .. tostring(requestedVariant) ..
                " | matchableCount=" .. tostring(debugMatches))
            local MAX_MATCHING_CANDIDATES_PER_REQUEST = 2

            for _, b in ipairs(botHuges) do
                if not usedUUIDs[b.uuid]
                    and petMatches(
                        b,
                        req,
                        displayName,
                        requestedVariant
                    )
                then
                    matchingCandidatesTried = matchingCandidatesTried + 1

                    if matchingCandidatesTried > MAX_MATCHING_CANDIDATES_PER_REQUEST then
                        warn(
                            "[WITHDRAWAL] Aborting candidate scan for " ..
                            tostring(displayName) ..
                            " after " ..
                            tostring(MAX_MATCHING_CANDIDATES_PER_REQUEST) ..
                            " failed matching UUIDs"
                        )
                        break
                    end

                    print(
                        "[WITHDRAWAL] Attempting SetItem for " ..
                        tostring(displayName) ..
                        " | matchedLocalPet=" ..
                        tostring(getNameById(b.id)) ..
                        " | petId=" ..
                        tostring(b.id) ..
                        " | UUID=" ..
                        tostring(b.uuid) ..
                        " | tradeCount=" ..
                        tostring(#itemsGiven + 1) ..
                        "/" ..
                        tostring(MAX_TRADE_PETS)
                    )

                    local ok, result = addPet(b.uuid)

                    if ok then
                        usedUUIDs[b.uuid] = true

                        table.insert(
                            itemsGiven,
                            {
                                name =
                                    displayName
                                    or getNameById(b.id),

                                uuid = b.uuid,

                                petConfigId = petId,

                                variant =
                                    requestedVariant,
                            }
                        )

                        found = true

                        print(
                            "[WITHDRAWAL] Added + verified requested pet: " ..
                            tostring(displayName) ..
                            " | UUID=" ..
                            tostring(b.uuid)
                        )

                        if (#itemsGiven % 10) == 0 then
                            print(
                                "[WITHDRAWAL] BULK PROGRESS: " ..
                                tostring(#itemsGiven) ..
                                " pets successfully prepared"
                            )
                        end

                        break

                    else
                        warn(
                            "[WITHDRAWAL] SetItem failed for " ..
                            tostring(displayName) ..
                            ": " ..
                            tostring(result)
                        )
                    end
                end
            end

            if not found then
                table.insert(
                    missingPets,
                    tostring(displayName)
                )

                print(
                    "[WITHDRAWAL] Missing from inventory, skipping: " ..
                    tostring(displayName)
                )
            end
        end

        if petLimitReached then
            break
        end
    end

    lastWithdrawalMissing = {
        pets = missingPets,
        gems = 0,
    }

    lastGemsRequested = gemsRequested
    lastBotGemsAdded = 0

    if gemsRequested > 0 then
        local botBalance = getBotGemBalance()

        if botBalance >= gemsRequested then
            addGems(gemsRequested)

            lastBotGemsAdded = gemsRequested

            print(
                "[WITHDRAWAL] Added requested gems: " ..
                tostring(gemsRequested)
            )

        elseif botBalance > 0 then
            addGems(botBalance)

            lastBotGemsAdded = botBalance

            lastWithdrawalMissing.gems =
                gemsRequested - botBalance

            print(
                "[WITHDRAWAL] Partial gems: sent " ..
                tostring(botBalance) ..
                ", missing " ..
                tostring(lastWithdrawalMissing.gems)
            )

        else
            lastWithdrawalMissing.gems =
                gemsRequested

            print(
                "[WITHDRAWAL] Missing gems, skipping: " ..
                tostring(gemsRequested)
            )
        end
    end

    local anythingAdded =
        (#itemsGiven > 0)
        or (lastBotGemsAdded > 0)

    if not anythingAdded then
        local reason =
            "No requested withdrawal items were available"

        if #missingPets > 0 then
            reason =
                reason ..
                ": " ..
                table.concat(
                    missingPets,
                    ", "
                )

        elseif gemsRequested > 0 then
            reason =
                "No requested items or gems were available"
        end

        return {}, 0, false, reason
    end

    print(
        "[WITHDRAWAL] Prepared withdrawal: " ..
        tostring(#itemsGiven) ..
        " pets + " ..
        tostring(lastBotGemsAdded) ..
        " gems"
    )
    print(
        "[WITHDRAWAL-COUNT] Exact bot-side items added=" ..
        tostring(#itemsGiven) ..
        " | requested pet entries=" .. tostring(#requestedItems)
    )

    if #missingPets > 0 then
        print(
            "[WITHDRAWAL] Still pending: " ..
            table.concat(
                missingPets,
                ", "
            )
        )
    end

    if lastWithdrawalMissing.gems > 0 then
        print(
            "[WITHDRAWAL] Still pending gems: " ..
            tostring(lastWithdrawalMissing.gems)
        )
    end

    return itemsGiven, lastBotGemsAdded, true
end

-- ============================================================
-- TRADE COMPLETION
-- ============================================================
local function handleTradeCompletion(tradeMethod)
    if tradeProcessed then return end
    tradeProcessed = true

    print("[COMPLETE] " .. tostring(tradeMethod) .. " | " .. tostring(lastTradeUsername))

    local function tryProcessDeposit(bypassMin)
        if not lastTradeUsername or lastTradeUsername == "" then return end
        if #lastTradeItems == 0 and lastTradeGems == 0 then return end
        print("[COMPLETE] Processing deposit: " .. #lastTradeItems .. " pets, " .. lastTradeGems .. " gems (bypassMin=" .. tostring(bypassMin) .. ")")
        local success, result = processDeposit(lastTradeUserId, lastGameTradeId, lastTradeItems, lastTradeGems, bypassMin)
        if success then
            sendMessage("Deposited " .. tostring(result) .. " items!")
            if lastTradeGems > 0 then sendMessage("Plus " .. formatDepositGemCredit(lastTradeGems) .. "!") end
            local itemList = ""
            for i, item in ipairs(lastTradeItems) do
                if i <= 10 then
                    local label = type(item) == "table" and item.name or tostring(item)
                    itemList = itemList .. "- " .. tradeItemDisplay(label) .. "\n"
                end
            end
            if #lastTradeItems > 10 then itemList = itemList .. "... +" .. (#lastTradeItems - 10) .. " more\n" end
            sendDiscord("**DEPOSIT COMPLETED**\n**Player:** " .. lastTradeUsername ..
                "\n**Items:** " .. tostring(result) .. "\n**Gems:** " .. tostring(lastTradeGems) ..
                "\n\n" .. itemList, 65280)
        else
            -- Plain ASCII - Roblox's chat filter can reject an entire
            -- message over a single character it doesn't like, and this is
            -- the one message telling the player something went wrong.
            sendMessage("WARNING: Deposit error - your items may not have been credited: " .. tostring(result))
            sendDiscord("DEPOSIT FAILED: " .. lastTradeUsername .. " | " .. tostring(result), 16711680)
        end
    end

    if tradeMethod == "deposit" then
        if not lastTradeUsername or lastTradeUsername == "" then
            sendMessage("Error: No username recorded")
        elseif #lastTradeItems == 0 and lastTradeGems == 0 then
            sendMessage("Error: Nothing to deposit")
        else
            tryProcessDeposit(false)
        end

    elseif tradeMethod == "withdraw" then
        local wdData = lastWithdrawalData and (lastWithdrawalData.data or lastWithdrawalData)
        if wdData then
            local uiPets, uiGems = checkBotTradeItems()

            local fullItemsGiven = {}
            local gemsActuallySent = 0

            local trackedPetCount = #lastItemsGiven
            local uiLooksComplete = uiPets
                and #uiPets == trackedPetCount
                and (uiGems == 0 or uiGems == lastBotGemsAdded)

            if uiLooksComplete then
                print("[COMPLETE] UI snapshot matches tracked delivery: " .. #uiPets .. " pets, " .. uiGems .. " gems")

                local usedTracked = {}

                for _, petName in ipairs(uiPets) do
                    local wantedName = tostring(petName):lower()
                    local matchedIndex = nil

                    for index, tracked in ipairs(lastItemsGiven) do
                        if not usedTracked[index]
                            and tracked
                            and tracked.name
                            and tostring(tracked.name):lower() == wantedName
                        then
                            matchedIndex = index
                            break
                        end
                    end

                    if matchedIndex then
                        local tracked = lastItemsGiven[matchedIndex]
                        usedTracked[matchedIndex] = true

                        table.insert(fullItemsGiven, {
                            name = tracked.name,
                            uuid = tracked.uuid,
                            petConfigId = tracked.petConfigId,
                            variant = tracked.variant,
                        })

                        print("[COMPLETE] Matched delivered pet #" ..
                            tostring(#fullItemsGiven) ..
                            " | " .. tostring(tracked.name) ..
                            " | UUID=" .. tostring(tracked.uuid) ..
                            " | petConfigId=" .. tostring(tracked.petConfigId) ..
                            " | variant=" .. tostring(tracked.variant))
                    else
                        warn("[COMPLETE] UI pet could not be matched to an authoritative tracked item: " .. tostring(petName))
                    end
                end

                gemsActuallySent = tonumber(uiGems) or 0
            else
                warn("[COMPLETE] Bot trade UI incomplete (uiPets=" .. tostring(uiPets and #uiPets or 0) ..
                    ", trackedPets=" .. tostring(trackedPetCount) ..
                    ", uiGems=" .. tostring(uiGems or 0) ..
                    ") - using authoritative tracked delivery")

                for _, tracked in ipairs(lastItemsGiven) do
                    if tracked and tracked.type ~= "gems" then
                        table.insert(fullItemsGiven, {
                            name = tracked.name,
                            uuid = tracked.uuid,
                            petConfigId = tracked.petConfigId,
                            variant = tracked.variant,
                        })
                    end
                end

                if lastBotGemsAdded > 0 then
                    gemsActuallySent = tonumber(lastBotGemsAdded) or 0
                    print("[COMPLETE] Gem fallback: using lastBotGemsAdded=" .. tostring(gemsActuallySent))
                else
                    gemsActuallySent = math.max(0,
                        (tonumber(lastGemsRequested) or 0) -
                        (tonumber(lastWithdrawalMissing.gems) or 0))

                    if gemsActuallySent > 0 then
                        print("[COMPLETE] Gem fallback: derived from requested-missing=" .. tostring(gemsActuallySent))
                    else
                        print("[COMPLETE] Gem fallback: bot sent 0 gems (insufficient balance)")
                    end
                end
            end

            if gemsActuallySent > 0 then
                table.insert(fullItemsGiven, { name = "gems", type = "gems", value = gemsActuallySent })
            end

            print("[COMPLETE] Confirming withdrawal - pets=" .. (#fullItemsGiven - (gemsActuallySent > 0 and 1 or 0)) .. " gems=" .. gemsActuallySent)

            local confirmationUserId = lastTradeUserId
            local confirmationWithdrawal = wdData
            local confirmationTradeId = tradeId
            local confirmationUsername = tostring(lastTradeUsername or "Unknown")

            local confirmationItems = {}
            for _, item in ipairs(fullItemsGiven) do
                table.insert(confirmationItems, {
                    name = item.name,
                    uuid = item.uuid,
                    petConfigId = item.petConfigId,
                    variant = item.variant,
                    type = item.type,
                    value = item.value,
                })
            end

            local confirmationMissingPets = {}
            for _, pet in ipairs(lastWithdrawalMissing.pets or {}) do
                table.insert(confirmationMissingPets, pet)
            end

            local confirmationMissingGems = tonumber(lastWithdrawalMissing.gems) or 0
            local confirmationSentGems = tonumber(gemsActuallySent) or 0

            local confirmed, confirmError = confirmWithdrawal(
                confirmationUserId,
                confirmationWithdrawal,
                confirmationTradeId,
                confirmationItems,
                confirmationMissingPets,
                confirmationMissingGems,
                confirmationSentGems
            )

            if not confirmed then
                warn("[COMPLETE] Withdrawal confirmation failed after Roblox trade succeeded: " .. tostring(confirmError))

                task.spawn(function()
                    local maxBackgroundAttempts = 20

                    for attempt = 1, maxBackgroundAttempts do
                        local delaySeconds = math.min(5 * attempt, 30)
                        task.wait(delaySeconds)

                        print("[COMPLETE-RETRY] Retrying withdrawal confirmation " ..
                            tostring(attempt) .. "/" .. tostring(maxBackgroundAttempts) ..
                            " | withdrawalId=" .. tostring(confirmationWithdrawal.id))

                        local retryOk, retryResult = confirmWithdrawal(
                            confirmationUserId,
                            confirmationWithdrawal,
                            confirmationTradeId,
                            confirmationItems,
                            confirmationMissingPets,
                            confirmationMissingGems,
                            confirmationSentGems
                        )

                        if retryOk then
                            print("[COMPLETE-RETRY] Withdrawal successfully confirmed! | withdrawalId=" .. tostring(confirmationWithdrawal.id))

                            completedWithdrawals[tostring(confirmationUserId)] = {
                                id = tostring(confirmationWithdrawal.id),
                                at = os.time(),
                                complete = (#confirmationMissingPets == 0 and confirmationMissingGems == 0),
                            }

                            sendDiscord(
                                "**WITHDRAWAL CONFIRMED ON RETRY**\n" ..
                                "**Player:** " .. confirmationUsername ..
                                "\n**Withdrawal ID:** " .. tostring(confirmationWithdrawal.id) ..
                                "\n**Attempt:** " .. tostring(attempt),
                                65280
                            )

                            return
                        end

                        warn("[COMPLETE-RETRY] Attempt " .. tostring(attempt) .. "/" ..
                            tostring(maxBackgroundAttempts) .. " failed: " .. tostring(retryResult))
                    end

                    sendDiscord(
                        "**CRITICAL: WITHDRAWAL CONFIRMATION STILL FAILED**\n" ..
                        "**Player:** " .. confirmationUsername ..
                        "\n**Withdrawal ID:** " .. tostring(confirmationWithdrawal.id) ..
                        "\n**The Roblox trade succeeded, but backend confirmation could not be completed after all recovery attempts.**",
                        16711680
                    )

                    warn("[COMPLETE-RETRY] Exhausted all background confirmation attempts | withdrawalId=" ..
                        tostring(confirmationWithdrawal.id))
                end)
            end

            local itemList = ""
            for i, item in ipairs(fullItemsGiven) do
                if i <= 10 then
                    itemList = itemList .. "- " .. (item.name or "?")
                        .. (item.value and (" (" .. tostring(item.value) .. ")") or "") .. "\n"
                end
            end
            local petCount   = #fullItemsGiven - (gemsActuallySent > 0 and 1 or 0)
            local isPartial  = #lastWithdrawalMissing.pets > 0 or lastWithdrawalMissing.gems > 0
            local missingStr = ""
            if #lastWithdrawalMissing.pets > 0 then
                missingStr = missingStr .. "\n**Missing pets:** " .. table.concat(lastWithdrawalMissing.pets, ", ")
            end
            if lastWithdrawalMissing.gems > 0 then
                missingStr = missingStr .. "\n**Missing gems:** " .. lastWithdrawalMissing.gems
            end

            if confirmed then
                completedWithdrawals[tostring(lastTradeUserId)] = {
                    id = tostring(lastWithdrawalData and lastWithdrawalData.data and lastWithdrawalData.data.id or ""),
                    at = os.time(),
                    complete = not isPartial,
                }
                if isPartial then
                    sendMessage("Partial withdrawal sent! Remaining items stay pending - trade again to get the rest.")
                    sendDiscord("**PARTIAL WITHDRAWAL**\n**Player:** " .. tostring(lastTradeUsername) ..
                        "\n**Pets sent:** " .. petCount .. "\n**Gems sent:** " .. gemsActuallySent ..
                        missingStr .. "\n\n" .. itemList, 16776960)
                else
                    sendMessage("Withdrawal complete!")
                    sendDiscord("**WITHDRAWAL COMPLETED**\n**Player:** " .. tostring(lastTradeUsername) ..
                        "\n**Pets sent:** " .. petCount .. "\n**Gems sent:** " .. gemsActuallySent ..
                        "\n\n" .. itemList, 65280)
                end
            else
                sendMessage("WARNING: Withdrawal sent but confirm had issues - contact support if balance wrong")
                sendDiscord("**WITHDRAWAL (confirm issue)**\n**Player:** " .. tostring(lastTradeUsername) ..
                    "\n**Pets sent:** " .. petCount .. "\n**Gems sent:** " .. gemsActuallySent ..
                    (isPartial and ("\n**PARTIAL**" .. missingStr) or "") ..
                    "\n**Note:** Items were traded, confirm endpoint failed.\n" .. itemList, 16711680)
            end
        end

        -- No tryProcessDeposit(true) here on purpose: withdrawals can no
        -- longer carry any deposit items (see the WITHDRAW-GUARD cancel
        -- in connectStatus) - combining the two in one trade was the dupe
        -- glitch the operator flagged, for Huge pets and gems specifically.
    end

    print("[COMPLETE] Releasing trade and closing window")
    pcall(function() tradingCommands.Close() end)
    task.wait(0.05)

    resetTradeState()
    goNext = true
    releaseIncomingTradeLock()
end

-- ============================================================
-- CONFIRM MONITOR
-- ============================================================
local function connectConfirm(localId, tradeMethod, validatedItems, validatedGems)
    task.spawn(function()
        task.wait()
        if goNext or tradeCancelled or tradeId ~= localId then return end
        if not isInTrade() then return end

        local isWithdraw = tradeMethod == "withdraw"
        local _, confirmItems = checkItems(isWithdraw)
        local confirmGems     = client_trade_gems()

        local swapped = false
        if confirmGems ~= validatedGems then
            warn("[CONFIRM-CHECK] Gem mismatch! Validated=" .. validatedGems .. " Now=" .. confirmGems)
            swapped = true
        end
        if #confirmItems ~= #validatedItems then
            warn("[CONFIRM-CHECK] Item count mismatch! Validated=" .. #validatedItems .. " Now=" .. #confirmItems)
            swapped = true
        else
            -- Entries are {name, cosmicValue, demand} tables now, not bare
            -- strings - compare by `name` (the identityKey), not `==`
            -- (two different table instances for the "same" pet are never
            -- == to each other).
            local function entryKey(v)
                return type(v) == "table" and v.name or tostring(v)
            end
            local validatedCopy = {}
            for _, v in ipairs(validatedItems) do table.insert(validatedCopy, v) end
            for _, item in ipairs(confirmItems) do
                local found = false
                local itemKey = entryKey(item)
                for i, v in ipairs(validatedCopy) do
                    if entryKey(v) == itemKey then table.remove(validatedCopy, i); found = true; break end
                end
                if not found then
                    warn("[CONFIRM-CHECK] Item '" .. tostring(itemKey) .. "' not in validated list - possible swap!")
                    swapped = true; break
                end
            end
        end

        if swapped then
            sendMessage("Trade items changed after ready - cancelling!")
            sendDiscord("🚨 **POSSIBLE SWAP ATTACK**\n**Player:** " .. tostring(lastTradeUsername) ..
                "\n**Method:** " .. tradeMethod ..
                "\n**Validated:** " .. #validatedItems .. " pets + " .. validatedGems .. " gems" ..
                "\n**At confirm:** " .. #confirmItems .. " pets + " .. confirmGems .. " gems" ..
                "\nTrade cancelled automatically.", 16711680)
            tradeCancelled = true
            tradeProcessed = true
            if isWithdraw and lastWithdrawalData then
                local wdData = lastWithdrawalData.data or lastWithdrawalData
                cancelWithdrawalTrade(wdData, "Swap detected at confirm stage", true)
            end
            declineTrade()
            goNext = true
            releaseIncomingTradeLock()
            resetTradeState()
            return
        end

        lastTradeItems = confirmItems
        lastTradeGems  = confirmGems
        print("[CONFIRM-CHECK] ✅ User side verified (" .. tradeMethod .. "): " .. #confirmItems .. " pets + " .. confirmGems .. " gems")

        pcall(function() tradingCommands.SetConfirmed(true) end)
        task.wait()
        local ok, state = pcall(function() return tradingCommands.GetState() end)
        local confirmed = false
        if ok and state then
            local myId = tostring(localPlayer.UserId)
            if type(state._confirmed) == "table" and state._confirmed[myId] then confirmed = true end
            if not confirmed then
                for uid, ps in pairs(state) do
                    if tostring(uid) == myId and type(ps) == "table" and (ps.confirmed or ps.Confirmed) then
                        confirmed = true; break
                    end
                end
            end
        end

                if confirmed then
            botConfirmed = true
            sendMessage("Trade confirmed!")
            print("[CONFIRM] Confirmed via GetState")
        else
            warn("[CONFIRM] Could not verify via GetState - marking confirmed anyway")
            botConfirmed = true
            sendMessage("Trade confirmed!")
        end
    end)

end

-- ============================================================
-- STATUS MONITOR
-- ============================================================
local function connectStatus(localId, tradeMethod)
    task.spawn(function()
        local startTime    = tick()
        local wasReady     = false
        local confirmFired = false

        local notReadyCount = 0
        local READY_LOSS_THRESHOLD = 4

        local validationRunning = false

        while (tick() - startTime) < TRADE_TIMEOUT_SECONDS
            and not goNext
            and tradeId == localId do

            local nowReady = isPlayerReady()

            if wasReady and not nowReady and not confirmFired then
                notReadyCount = notReadyCount + 1

                if notReadyCount >= READY_LOSS_THRESHOLD then
                    print("[STATUS] Player UN-READED - resetting validation, re-checking on next ready")
                    sendMessage("Please re-ready with your items.")

                    pcall(function() tradingCommands.SetReady(false) end)
                    botReadied     = false
                    hasReadied      = false
                    lastTradeItems  = {}
                    lastTradeGems   = 0
                    wasReady        = false
                    validationRunning = false
                    notReadyCount   = 0
                end
            else
                notReadyCount = 0
            end

            if not wasReady and nowReady and not confirmFired and not validationRunning then
                wasReady = true
                notReadyCount = 0
                validationRunning = true

                print("[STATUS] Player clicked ready - validating items...")

                if tradeMethod == "deposit" then
                    local hasError, output = checkItems()
                    if hasError then
                        sendMessage(tostring(output))
                        pcall(function() tradingCommands.SetReady(false) end)

                        wasReady = true
                        task.wait(1)
                    else
                        local depositGems = client_trade_gems()
                        lastTradeItems = output
                        lastTradeGems  = depositGems
                        hasReadied     = true
                            sendMessage("Validated: " .. #lastTradeItems .. " pets + " .. formatDepositGemCredit(depositGems))

                            local readied = false
                            for i = 1, 3 do
                                if goNext or tradeId ~= localId then break end
                                readied = readyTrade()
                                botReadied = readied == true
                                if readied then break end
                                humanDelay(200, 400)
                            end

                            if not readied then
                                warn("[READY] Bot could not send SetReady(true) after 3 attempts")
                                sendMessage("Bot could not ready the trade. Please re-open the trade and try again.")
                                pcall(function() tradingCommands.SetReady(false) end)
                                validationRunning = false
                                wasReady = true
                            else
                                sendMessage("Bot READY - click confirm!")
                                confirmFired = true
                                validationRunning = false
                                connectConfirm(localId, tradeMethod, lastTradeItems, lastTradeGems)
                            end
                    end

                elseif tradeMethod == "withdraw" then
                    local hasError, output = checkItems(true)
                    local depositGems = client_trade_gems()

                    -- Adding pets/gems to a withdrawal trade used to get
                    -- processed as a bonus deposit once the withdrawal
                    -- completed (tryProcessDeposit(true) in
                    -- handleTradeCompletion) - operator identified this as
                    -- a dupe glitch, specifically for Huge pets and gems.
                    -- Withdrawals and deposits are no longer allowed to
                    -- combine in one trade: if the player added ANYTHING
                    -- on their side during a withdrawal, cancel outright
                    -- instead of readying.
                    if (not hasError and #output > 0) or depositGems > 0 then
                        warn("[WITHDRAW-GUARD] Player added items/gems during withdrawal - declining trade to prevent dupe (pets=" ..
                            tostring(#output) .. " gems=" .. tostring(depositGems) .. ")")
                        sendMessage("Don't add items/gems during a withdrawal - trade cancelled. Re-trade to try again.")
                        tradeCancelled = true
                        tradeProcessed = true
                        if lastWithdrawalData then
                            local wdData = lastWithdrawalData.data or lastWithdrawalData
                            cancelWithdrawalTrade(wdData, "Items/gems added during withdrawal - dupe prevention", true)
                        end
                        declineTrade()
                        goNext = true
                        releaseIncomingTradeLock()
                        resetTradeState()
                        return
                    elseif hasError then
                        sendMessage(tostring(output))
                        pcall(function() tradingCommands.SetReady(false) end)
                        wasReady = true
                        task.wait(1)
                    else
                            lastTradeItems = output
                            lastTradeGems  = depositGems
                            hasReadied     = true

                            sendMessage("Processing your withdrawal...")

                            if #lastWithdrawalMissing.pets > 0 then
                                sendMessage("Note: " .. #lastWithdrawalMissing.pets .. " pet(s) out of stock - will stay pending")
                            end
                            if lastWithdrawalMissing.gems > 0 then
                                sendMessage("Note: " .. lastWithdrawalMissing.gems .. " gems still owed - will stay pending")
                            end

                            local readied = false
                            for i = 1, 3 do
                                if goNext or tradeId ~= localId then break end
                                readied = readyTrade()
                                botReadied = readied == true
                                if readied then break end
                                humanDelay(200, 400)
                            end

                            if not readied then
                                warn("[READY] Bot could not send SetReady(true) after 3 attempts")
                                sendMessage("Bot could not ready the trade. Please re-open the trade and try again.")
                                pcall(function() tradingCommands.SetReady(false) end)
                                validationRunning = false
                                wasReady = true
                            else
                                sendMessage("Bot READY - click confirm!")
                                confirmFired = true
                                validationRunning = false
                                connectConfirm(localId, tradeMethod, lastTradeItems, lastTradeGems)
                            end
                    end
                end
            end

            if wasReady and not nowReady and confirmFired and tradeMethod == "deposit" and not tradeProcessed and not tradeCancelled then
                task.wait(1)
                if tradeProcessed or tradeCancelled then
                    print("[STATUS] Trade already completed during grace period - skipping cancel")
                    return
                end
                warn("[STATUS] Deposit: user unreadied after confirm was fired - declining to prevent swap abuse")
                sendMessage("Trade items changed - cancelling for safety!")
                tradeCancelled = true
                tradeProcessed = true
                declineTrade()
                goNext = true
                releaseIncomingTradeLock()
                resetTradeState()
                return
            end

            if not isInTrade() then break end
            task.wait(math.random(15, 35) / 1000)
        end
    end)
end

-- ============================================================
-- MESSAGE LISTENER
-- ============================================================
local function connectMessage(localId, tradeMethod)
    if not tradingMessage then
        tradingMessage = playerGUI:FindFirstChild("Message")
    end
    if not tradingMessage then
        warn("[MSG] tradingMessage not found - bot cannot detect trade completion!")
        sendDiscord("⚠️ **WARNING**: tradingMessage GUI not found - bot cannot detect trade completion for " .. tostring(lastTradeUsername), 16711680)
        return
    end

    local msgConn
    msgConn = tradingMessage:GetPropertyChangedSignal("Enabled"):Connect(function()
        if not tradingMessage.Enabled then return end

        local text = ""
        pcall(function() text = tradingMessage.Frame.Contents.Desc.Text end)
        if text == "" then pcall(function() text = tradingMessage.Frame.Desc.Text end) end
        if text == "" then
            pcall(function()
                for _, c in pairs(tradingMessage.Frame:GetDescendants()) do
                    if c:IsA("TextLabel") and c.Text ~= "" then text = c.Text; break end
                end
            end)
        end

        print("[MSG] '" .. text .. "'")
        local low = text:lower()

        if low:find("success") or low:find("complet") then
            msgConn:Disconnect()
            print("[MSG] SUCCESS message confirmed - processing trade")
            handleTradeCompletion(tradeMethod)
            pcall(function() tradingMessage.Enabled = false end)

        elseif low:find("cancel") or low:find("left") or low:find("decline") then
            msgConn:Disconnect()
            tradeCancelled = true
            tradeProcessed = true
            sendMessage("Trade cancelled")
            if tradeMethod == "withdraw" and lastWithdrawalData and lastWithdrawalData.data then
                local saved = cancelWithdrawalTrade(lastWithdrawalData.data, "Cancelled by player", true)
                sendMessage(saved and "Withdrawal saved - try again!" or "Contact support!")
                sendDiscord((saved and "Withdrawal saved: " or "Withdrawal cancel failed: ") .. tostring(lastTradeUsername), 16776960)
            else
                sendDiscord("Trade cancelled: " .. tostring(lastTradeUsername), 16711680)
            end
            releaseIncomingTradeLock()
            goNext = true
            pcall(function() tradingMessage.Enabled = false end)
            goNext = true
            resetTradeState()

        elseif text ~= "" then
            print("[MSG] Unrecognised message (ignoring): '" .. text .. "'")
            pcall(function() tradingMessage.Enabled = false end)
        end
    end)

    task.spawn(function()
        local startTime = tick()
        while (tick() - startTime) < TRADE_TIMEOUT_SECONDS and not goNext and tradeId == localId do
            task.wait(0.5)
        end
        if not tradeProcessed and not tradeCancelled and not goNext then
            warn("[MSG] Trade ended without success message - NOT processing to avoid incorrect trade")
            sendDiscord("⚠️ **TRADE NO-MSG**\n**Player:** " .. tostring(lastTradeUsername) ..
                "\n**Method:** " .. tostring(tradeMethod) ..
                "\nTrade ended but no success message received - items NOT processed. Check manually.", 16776960)
            pcall(function() msgConn:Disconnect() end)
            if tradeMethod == "withdraw" and lastWithdrawalData and lastWithdrawalData.data then
                cancelWithdrawalTrade(lastWithdrawalData.data, "No success message received", true)
            end

            goNext = true
            tradeId = 0
            lastGameTradeId = nil
            method = nil
            releaseIncomingTradeLock()
            resetTradeState()
            print("[TRADE] No-message cleanup complete - ready for next trade")
        end
    end)
end

-- ============================================================
-- STARTUP: LOAD ITEMS
-- ============================================================
print("========================================")
print("[BOT] BloxyFlip Bot v2.7-simple Starting (base script + real Cosmic Value wiring)...")
print("[BOT] Bot ID: " .. BOT_ID)
print("[BOT] API:    " .. website)
print("========================================")

local itemsLoaded = false
for attempt = 1, 5 do
    print("[BOT] Loading items - attempt " .. attempt .. "/5...")
    if GetSupported() then itemsLoaded = true; break end
    if attempt < 5 then task.wait(3) end
end

if not itemsLoaded then
    error("[BOT] CRITICAL: Could not load items after 5 attempts. Check API and credentials!")
end

print("[BOT] [OK] Ready! " .. #supporteditems .. " live catalog entries loaded.")

-- ============================================================
-- ANTI-AFK — Hoverboard toggle every 15s
-- ============================================================
task.spawn(function()
    task.wait(8)

    local keypressFunc   = getgenv().keypress   or (syn and syn.keypress)
    local keyreleaseFunc = getgenv().keyrelease  or (syn and syn.keyrelease)
    local Q_KEY = 81

    local function findHoverButton()
        local gui = localPlayer:FindFirstChildOfClass("PlayerGui")
        if not gui then return nil end
        for _, obj in ipairs(gui:GetDescendants()) do
            if (obj:IsA("ImageButton") or obj:IsA("TextButton")) and obj.Visible then
                local n = obj.Name:lower()
                local p = obj.Parent and obj.Parent.Name:lower() or ""
                if n:find("hover") or n:find("board") or n:find("vehicle")
                or n:find("mount") or n:find("ride") or n:find("glider")
                or p:find("hover") or p:find("vehicle") or p:find("board") then
                    print("[ANTI-AFK] Found hoverboard button: " .. obj:GetFullName())
                    return obj
                end
            end
        end
        return nil
    end

    local function findHoverRemote()
        for _, obj in ipairs(replicatedStorage:GetDescendants()) do
            if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") then
                local n = obj.Name:lower()
                if n:find("hover") or n:find("vehicle") or n:find("board")
                or n:find("mount") or n:find("ride") or n:find("glider") then
                    print("[ANTI-AFK] Found hoverboard remote: " .. obj:GetFullName())
                    return obj
                end
            end
        end
        return nil
    end

    -- Real fix (operator report, 2026-10-12): these two were full,
    -- blocking scans of the ENTIRE PlayerGui and ReplicatedStorage trees -
    -- for a game the size of PS99, that's tens of thousands of instances,
    -- done eagerly at the 8-second mark regardless of whether they'd ever
    -- actually be needed. Now lazy: only run the first time keypress
    -- genuinely isn't available/doesn't work, which for most executors
    -- never happens at all, so most sessions never pay this cost.
    local hoverButton = nil
    local hoverRemote = nil
    local hoverLookupDone = false

    while true do
        task.wait(15)

        if isInTrade() then
            print("[ANTI-AFK] Skipping - actual trade is open")
            continue
        end

        local toggled = false

        if not toggled and keypressFunc and keyreleaseFunc then
            pcall(function()
                keypressFunc(Q_KEY)
                task.wait(0.1)
                keyreleaseFunc(Q_KEY)
                task.wait(2)
                keypressFunc(Q_KEY)
                task.wait(0.1)
                keyreleaseFunc(Q_KEY)
                print("[ANTI-AFK] Q toggled via executor keypress")
                toggled = true
            end)
        end

        if not toggled and not hoverLookupDone then
            hoverLookupDone = true
            hoverButton = findHoverButton()
            hoverRemote = findHoverRemote()
        end

        if not toggled and hoverButton then
            pcall(function()
                hoverButton:Activate()
                task.wait(2)
                hoverButton:Activate()
                print("[ANTI-AFK] Hoverboard toggled via UI button")
                toggled = true
            end)
        end

        if not toggled and hoverRemote then
            pcall(function()
                if hoverRemote:IsA("RemoteEvent") then
                    hoverRemote:FireServer(true)
                    task.wait(2)
                    hoverRemote:FireServer(false)
                else
                    hoverRemote:InvokeServer(true)
                    task.wait(2)
                    hoverRemote:InvokeServer(false)
                end
                print("[ANTI-AFK] Hoverboard toggled via remote")
                toggled = true
            end)
        end

        if not toggled then
            -- Real fix (operator report, 2026-10-12): this used to re-run
            -- BOTH full-tree scans again every single 15-second cycle
            -- forever whenever nothing worked - the same expensive
            -- PlayerGui/ReplicatedStorage walk repeating indefinitely
            -- instead of the one-time lazy lookup above. No retry here
            -- any more; the single lookup already ran this session.
            warn("[ANTI-AFK] No toggle method worked this cycle")
        end

        pcall(function()
            virtualUser:CaptureController()
            virtualUser:Button2Down(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
            task.wait(0.05)
            virtualUser:Button2Up(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
        end)
    end
end)

pcall(function()
    localPlayer.Idled:Connect(function()
        warn("[ANTI-AFK] Roblox Idled fired - emergency input!")
        pcall(function()
            virtualUser:CaptureController()
            for _ = 1, 5 do
                virtualUser:Button1Down(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
                task.wait(0.03)
                virtualUser:Button1Up(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
                virtualUser:Button2Down(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
                task.wait(0.03)
                virtualUser:Button2Up(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
                task.wait(0.05)
            end
        end)
    end)
end)

-- ============================================================
-- KEEP-ALIVE
-- ============================================================
task.spawn(function()
    while true do
        pcall(function()
            local hum = localPlayer.Character and localPlayer.Character:FindFirstChild("Humanoid")
            if hum then hum:Move(Vector3.new(0,0,0)) end
        end)
        task.wait(math.random(30, 60))
    end
end)

-- ============================================================
-- HEARTBEAT
-- ============================================================
task.spawn(function()
    local function buildHeldItemsSnapshot()
        local snapshot = {}
        local ok, inventory = pcall(getHugesTitanics)
        if not ok or type(inventory) ~= "table" then
            warn("[HEARTBEAT] Could not read local Huge/Titanic inventory for reconciliation")
            return snapshot
        end

        local counts = {}
        for _, pet in ipairs(inventory) do
            local petId = pet and pet.id
            local variant = pet and pet.variant
            if petId and variant then
                local key = tostring(petId) .. "\31" .. tostring(variant)
                local entry = counts[key]
                if not entry then
                    entry = {
                        petId = tostring(petId),
                        petName = tostring(pet.name or getNameById(petId) or petId),
                        variant = tostring(variant),
                        quantity = 0,
                    }
                    counts[key] = entry
                    table.insert(snapshot, entry)
                end
                entry.quantity = entry.quantity + 1
            end
        end

        return snapshot
    end

    while true do
        local physicalGems = getBotGemBalance()
        local heldItems = buildHeldItemsSnapshot()

        local heartbeatPayload = {
            botId = BOT_ID,
            heldGems = physicalGems,
            heldItems = heldItems,
        }

        print("[HEARTBEAT] Sending inventory snapshot | gems=" ..
            tostring(physicalGems) .. " | heldItemGroups=" .. tostring(#heldItems))

        local hbOk, hbResp = makeAuthenticatedRequest(
            "/api/bots/heartbeat",
            heartbeatPayload,
            "POST"
        )

        if hbOk and hbResp and hbResp.StatusCode == 200 then
            local hbData = decodeBody(hbResp)

            if hbData then
                local rawHeld = hbData.heldGemsBalance
                local parsedHeld = tonumber(rawHeld)

                if rawHeld ~= nil and parsedHeld ~= nil and parsedHeld >= 0 then
                    botGemBalance = parsedHeld
                    botGemBalancePresent = true
                    print("[HEARTBEAT] OK | raw heldGemsBalance=" .. tostring(rawHeld) ..
                        " | parsed=" .. tostring(botGemBalance))
                elseif rawHeld ~= nil then
                    warn("[HEARTBEAT] heldGemsBalance present but invalid: " .. tostring(rawHeld))
                else
                    if type(hbData.gem_balance) == "number" then
                        botGemBalance = hbData.gem_balance
                        botGemBalancePresent = false
                        print("[HEARTBEAT] OK | heldGemsBalance absent; legacy gem_balance=" .. tostring(botGemBalance))
                    else
                        print("[HEARTBEAT] OK | heldGemsBalance absent | no legacy gem_balance (expected - not wired to any live decision here)")
                    end
                end
            end
        else
            warn("[HEARTBEAT] Request failed | status=" .. tostring(hbResp and hbResp.StatusCode or "?"))
        end

        task.wait(math.random(25, 35))
    end
end)

-- ============================================================
-- TRADE ID TRACKER
-- ============================================================
-- Operator report (2026-10-12): client crashing ~10s after execution,
-- right after updating their executor - this loop and the main trade loop
-- below are the two things running unconditionally, forever, from the
-- moment the script starts, calling into executor-hooked game functions
-- 10-20 times a SECOND each. Slowed down (0.1s -> 0.35s) as a safety
-- margin against whatever changed in the executor's handling of these
-- calls - still responsive enough to catch a new trade ID almost
-- instantly, just far less aggressive.
task.spawn(function()
    while task.wait(0.35) do
        local ok, err = pcall(function()
            tradeId = getTradeId()
        end)
        if not ok then
            warn("[WATCHDOG] Trade ID tracker iteration failed (continuing): " .. tostring(err))
        end
    end
end)

-- ============================================================
-- TRADE LOCK WATCHDOG
-- ============================================================
task.spawn(function()
    while true do
        task.wait(5)

        if activeIncomingTrade
            and not goNext
            and activeIncomingSince > 0
            and (tick() - activeIncomingSince) >= 90
            and not isInTrade()
        then
            warn("[TRADE-WATCHDOG] Stale incoming-trade lock detected - releasing safely")
            sendMessage("Trade didn't go through - please re-trade.")
            sendDiscord(
                "⚠️ **TRADE LOCK RECOVERY**\n" ..
                "A stale incoming-trade lock was detected after 90 seconds with no active Roblox trade.\n" ..
                "The bot released the lock without processing the trade.",
                16776960
            )

            goNext = true
            tradeId = 0
            lastGameTradeId = nil
            method = nil
            releaseIncomingTradeLock()
            resetTradeState()
        end
    end
end)

-- ============================================================
-- MAIN TRADE LOOP
-- ============================================================
task.spawn(function()
    while true do
        if type(tradingCommands) ~= "table" then
            warn("[BOT] TradingCommands unavailable - waiting...")
            task.wait(5)
            continue
        end

        -- Operator report (2026-10-12): client crashing ~10s after
        -- execution after an executor update - this loop calls into
        -- tradingCommands.GetAllRequests() (via getTrades()) up to 20
        -- times a second, forever, unconditionally, from the moment the
        -- script starts. Slowed down (0.05s -> 0.2s, ~5x/sec) as a safety
        -- margin - still fast enough that an incoming trade request gets
        -- picked up almost instantly, just far less aggressive on
        -- whatever changed in the executor's handling of these calls.
        task.wait(0.2)

        if not goNext or activeIncomingTrade then
            -- Bot is busy with an active trade (deposit OR withdrawal).
            -- Explicitly DECLINE any other incoming trade request right
            -- now instead of leaving it queued and silently ignored. A
            -- second request left pending while the current withdrawal is
            -- still being readied/confirmed/closed is exactly the window
            -- where leftover state from the first trade (lastTradeItems,
            -- lastItemsGiven, cvCache, etc.) could bleed into whatever
            -- trade gets auto-accepted next once the bot frees up - that's
            -- the dupe-risk scenario. Declining it now forces a clean,
            -- separate trade after the bot is actually free.
            local busyIncoming = getTrades()
            for _, busyTrade in ipairs(busyIncoming) do
                pcall(function()
                    if type(tradingCommands.DeclineRequest) == "function" then
                        tradingCommands.DeclineRequest(busyTrade)
                    end
                end)
            end
            continue
        end

        local incoming = getTrades()
        if #incoming == 0 then
            continue
        end

        local trade = incoming[1]
        local username = trade.Name
        local userId = tostring(trade.UserId)

        local holdUntil = tonumber(withdrawalHoldUntil[userId]) or 0
        if holdUntil > tick() then
            print("[TRADE] Ignoring repeated blocked-withdrawal request | user=" ..
                tostring(username) .. " | cooldown=" ..
                string.format("%.1fs", holdUntil - tick()))
            pcall(function()
                if type(tradingCommands.DeclineRequest) == "function" then
                    tradingCommands.DeclineRequest(trade)
                end
            end)
            continue
        else
            withdrawalHoldUntil[userId] = nil
        end

        if activeIncomingTrade then
            continue
        end

        activeIncomingTrade = true
        activeIncomingUserId = userId
        activeIncomingSince = tick()
        goNext = false

        print("[TRADE] Incoming from: " .. username .. " (" .. userId .. ") [LOCKED]")

        local userInfo = checkUserBanned(userId)

        print("[USER-LOOKUP] robloxUserId=" .. tostring(userId) ..
            " | success=" .. tostring(userInfo and userInfo.success) ..
            " | found=" .. tostring(userInfo and userInfo.found) ..
            " | bloxyflipUserId=" .. tostring(userInfo and userInfo.userId))

        if not userInfo or userInfo.success ~= true then
            warn("[USER-LOOKUP-GUARD] check-user-banned failed; refusing DEPOSIT MODE | user=" ..
                tostring(username) .. " | robloxUserId=" .. tostring(userId) ..
                " | error=" .. tostring(userInfo and userInfo.error or "UNKNOWN"))
            pcall(function()
                if type(tradingCommands.DeclineRequest) == "function" then
                    tradingCommands.DeclineRequest(trade)
                else
                    declineTrade()
                end
            end)
            sendMessage("BloxyFlip could not verify your account right now. Please try again.")
            goNext = true
            tradeId = 0
            lastGameTradeId = nil
            method = nil
            releaseIncomingTradeLock()
            resetTradeState()
            continue
        end

        if userInfo.banned == true then
            sendMessage("You are banned from BloxyFlip")
            sendMessage("Contact support on Discord")
            randomWait(2, 4)

            pcall(function()
                tradingCommands.DeclineRequest(trade)
            end)

            goNext = true
            releaseIncomingTradeLock()
            continue
        end

        if #supporteditems == 0 then
            sendMessage("Items not loaded - please wait and try again")
            randomWait(1, 3)

            goNext = true
            releaseIncomingTradeLock()
            continue
        end

        lastTradeUsername = username
        lastTradeUserId = userId

        resetTradeState()

        lastTradeUsername = username
        lastTradeUserId = userId

        local recentlyConfirmed = false
        local withdrawalData = nil

        if not recentlyConfirmed
            and userInfo.found == true
            and userInfo.userId
        then
            print(
                "[WITHDRAW] Checking for withdrawal for userId=" ..
                tostring(userInfo.userId)
            )

            withdrawalData = getPendingWithdrawal(userInfo.userId)

            if withdrawalData and withdrawalData.success == true then
                if withdrawalData.data then
                    local wd = withdrawalData.data
                    local lastDone = completedWithdrawals[tostring(userId)]
                    if lastDone and lastDone.complete == true and tostring(lastDone.id) == tostring(wd.id) then
                        recentlyConfirmed = true
                        print("[WITHDRAW] Ignoring duplicate backend withdrawal id=" .. tostring(wd.id))
                        withdrawalData = {
                            success = true,
                            data = nil,
                            blocked = false,
                            pendingWithdrawalExists = false,
                        }
                    else
                        print(
                            "[WITHDRAW] FOUND" ..
                            " | id=" .. tostring(wd.id) ..
                            " | status=" .. tostring(wd.status) ..
                            " | partial=" .. tostring(wd.partial) ..
                            " | gems=" .. tostring(wd.gemsAmount or wd.gems or 0)
                        )
                    end
                else
                    print("[WITHDRAW] Lookup succeeded | pendingWithdrawalExists=" ..
                        tostring(withdrawalData.pendingWithdrawalExists) ..
                        " | blocked=" .. tostring(withdrawalData.blocked))
                end
            else
                warn("[WITHDRAW] Lookup ERROR - refusing to treat response as DEPOSIT MODE | error=" ..
                    tostring(withdrawalData and withdrawalData.error or "UNKNOWN"))
            end
        end

        if withdrawalData
            and withdrawalData.success
            and withdrawalData.data
        then
            local wd = withdrawalData.data

            if userInfo.found ~= true
                or tostring(wd.userId) ~= tostring(userInfo.userId)
            then
                print(
                    "[WITHDRAW-GUARD] Claimed withdrawal belongs to another account; requeuing"
                )

                cancelWithdrawalTrade(
                    wd,
                    "Incoming trader does not match claimed withdrawal",
                    true
                )

                withdrawalData = nil
            end
        end

        if withdrawalData
            and withdrawalData.success == true
            and withdrawalData.pendingWithdrawalExists == false
            and userInfo.found == true
            and userInfo.userId
        then
            print("[WITHDRAW-GRACE] Re-checking confirmed no-withdrawal state before choosing trade mode")

            local grace = getPendingWithdrawal(userInfo.userId)

            if grace and grace.success == true then
                if grace.data or grace.pendingWithdrawalExists == true or grace.blocked == true then
                    withdrawalData = grace

                    if grace.data then
                        print("[WITHDRAW-GRACE] Withdrawal appeared during grace window | id=" ..
                            tostring(grace.data.id))
                    else
                        print("[WITHDRAW-GRACE] Active withdrawal exists during grace window | blocked=" ..
                            tostring(grace.blocked))
                    end
                else
                    withdrawalData = grace
                    print("[WITHDRAW-GRACE] Still confirmed no pending withdrawal")
                end
            else
                withdrawalData = grace or { success = false, error = "WITHDRAWAL_GRACE_FAILED" }
                warn("[WITHDRAW-GRACE] Lookup failed; refusing DEPOSIT MODE")
            end
        end

        if not withdrawalData
            or withdrawalData.success ~= true
        then
            warn("[WITHDRAW-GUARD] No valid successful withdrawal lookup; refusing DEPOSIT MODE | user=" ..
                tostring(username) .. " | error=" ..
                tostring(withdrawalData and withdrawalData.error or "NO_LOOKUP_RESULT"))

            pcall(function()
                if type(tradingCommands.DeclineRequest) == "function" then
                    tradingCommands.DeclineRequest(trade)
                else
                    declineTrade()
                end
            end)

            if userInfo and userInfo.found == false then
                sendMessage("Link your Roblox account at bloxyflip.fun first, then trade again!")
            else
                sendMessage("BloxyFlip could not verify your account. Please try again.")
            end

            withdrawalHoldUntil[userId] = tick() + WITHDRAWAL_HOLD_COOLDOWN
            goNext = true
            tradeId = 0
            lastGameTradeId = nil
            method = nil
            releaseIncomingTradeLock()
            resetTradeState()
            continue
        end

        if withdrawalData
            and withdrawalData.success == true
            and withdrawalData.pendingWithdrawalExists == true
            and not withdrawalData.data
        then
            local reason = tostring(withdrawalData.blockReason or "pending withdrawal")

            warn("[WITHDRAW-GUARD] Active withdrawal exists but has no fulfillable payload; refusing DEPOSIT MODE | user=" ..
                tostring(username) .. " | blocked=" .. tostring(withdrawalData.blocked) ..
                " | reason=" .. reason)

            pcall(function()
                if type(tradingCommands.DeclineRequest) == "function" then
                    tradingCommands.DeclineRequest(trade)
                else
                    declineTrade()
                end
            end)

            sendMessage("Your withdrawal is still active, but the bot cannot fulfill it yet.")
            sendMessage("Please wait for the withdrawal to become available, then trade again.")

            withdrawalHoldUntil[userId] = tick() + WITHDRAWAL_HOLD_COOLDOWN
            print("[WITHDRAW-GUARD] Set repeated-request cooldown for " ..
                tostring(username) .. " (" .. tostring(WITHDRAWAL_HOLD_COOLDOWN) .. "s)")

            goNext = true
            tradeId = 0
            lastGameTradeId = nil
            method = nil
            releaseIncomingTradeLock()
            resetTradeState()
            continue
        end

        local depositAllowed = (
            withdrawalData ~= nil
            and withdrawalData.success == true
            and withdrawalData.pendingWithdrawalExists == false
            and withdrawalData.data == nil
            and withdrawalData.blocked ~= true
        )

        if not depositAllowed and not (withdrawalData and withdrawalData.data) then
            warn("[DEPOSIT-GATE] BLOCKED | success=" ..
                tostring(withdrawalData and withdrawalData.success) ..
                " | pendingWithdrawalExists=" ..
                tostring(withdrawalData and withdrawalData.pendingWithdrawalExists) ..
                " | blocked=" ..
                tostring(withdrawalData and withdrawalData.blocked) ..
                " | hasWithdrawal=" ..
                tostring(withdrawalData and withdrawalData.data ~= nil))
        end

        if withdrawalData
            and withdrawalData.success == true
            and withdrawalData.data
        then
    print("[TRADE] WITHDRAWAL MODE: " .. username)

    goNext = false
    method = "withdraw"
    lastWithdrawalData = withdrawalData

    if withdrawalData.localInventoryFallback then
        print("[WITHDRAWAL-LOCAL-FALLBACK] Using bot-side inventory as source of truth for this withdrawal")
    end

    local localId = acceptTradeRequest(trade)

    tradeId = localId or 0
    lastGameTradeId = localId

    if localId then
        sendMessage("== WITHDRAWAL MODE ==")
        sendMessage("Bot is sending you your items.")
        sendDiscord("Withdrawal started: " .. username, 16776960)

        local itemsGiven = {}
        local gemsGiven = 0
        local fullyAdded = false
        local addErr = nil

        local prepStage = "before addWithdrawalItems"
        local addOk, addResult = xpcall(function()
            prepStage = "enter addWithdrawalItems"
            local items, gems, complete, err =
                addWithdrawalItems(withdrawalData.data)

            prepStage = "addWithdrawalItems returned"

            return {
                items = items or {},
                gems = tonumber(gems) or 0,
                complete = complete == true,
                error = err,
            }
        end, function(err)
            local trace = debug and debug.traceback
                and debug.traceback(tostring(err), 2)
                or tostring(err)

            warn("[WITHDRAWAL-DIAG] PREP ERROR stage=" ..
                tostring(prepStage) ..
                " | traceback=" ..
                tostring(trace))

            return {
                __prepError = true,
                stage = prepStage,
                error = tostring(err),
                traceback = trace,
            }
        end)

        if addOk and type(addResult) == "table" then
            itemsGiven = addResult.items or {}
            gemsGiven = tonumber(addResult.gems) or 0
            fullyAdded = addResult.complete == true
            addErr = addResult.error
        elseif not addOk then
            addErr = tostring(addResult)
        elseif type(addResult) == "table" and addResult.__prepError then
            addErr =
                "Withdrawal preparation Lua error at stage " ..
                tostring(addResult.stage) ..
                ": " ..
                tostring(addResult.error) ..
                " | " ..
                tostring(addResult.traceback)
        else
            addErr = "Invalid withdrawal preparation result"
        end

        if not fullyAdded then
            warn(
                "[WITHDRAWAL] Could not prepare withdrawal: " ..
                tostring(addErr)
            )

            sendMessage(
                "Unable to prepare the withdrawal - please try again"
            )

            sendDiscord(
                "**WITHDRAWAL REQUEUED**\n" ..
                "**Player:** " ..
                username ..
                "\n" ..
                tostring(addErr),
                16776960
            )

            cancelWithdrawalTrade(
                withdrawalData.data,
                addErr or "Item add error",
                true
            )

            declineTrade()

            goNext = true
            releaseIncomingTradeLock()
            resetTradeState()

            continue
        end

        lastItemsGiven = itemsGiven
        lastBotGemsAdded = gemsGiven

        if #itemsGiven > 0 then
            sendMessage(
                "Added " ..
                tostring(#itemsGiven) ..
                " pets to trade!"
            )
        end

        if gemsGiven > 0 then
            sendMessage(
                "Added " ..
                tostring(gemsGiven) ..
                " gems to trade!"
            )
        end

        if lastWithdrawalMissing
            and #lastWithdrawalMissing.pets > 0
        then
            sendMessage(
                "Note: " ..
                tostring(#lastWithdrawalMissing.pets) ..
                " pet(s) are out of stock and will stay pending."
            )
        end

        if lastWithdrawalMissing
            and tonumber(lastWithdrawalMissing.gems or 0) > 0
        then
            sendMessage(
                "Note: " ..
                tostring(lastWithdrawalMissing.gems) ..
                " gems are still owed and will stay pending."
            )
        end

        print(
            "[WITHDRAWAL] Everything available has been added."
        )

        print(
            "[WITHDRAWAL] Bot is READYING immediately..."
        )

        local readyOk = false

        for attempt = 1, 3 do
            if goNext or tradeId ~= localId then
                break
            end

            readyOk = readyTrade()
            botReadied = readyOk == true

            if readyOk then
                print(
                    "[WITHDRAWAL] Bot READY successfully on attempt " ..
                    tostring(attempt)
                )
                break
            end

            if attempt < 3 then
                task.wait(0.15)
            end
        end

        if not readyOk then
            warn(
                "[WITHDRAWAL] Bot could not READY after adding items"
            )

            sendMessage(
                "Bot could not ready the trade. Please try again."
            )

            sendDiscord(
                "**WITHDRAWAL READY FAILED**\n" ..
                "**Player:** " ..
                username,
                16776960
            )

            cancelWithdrawalTrade(
                withdrawalData.data,
                "Failed to ready after adding withdrawal items",
                true
            )

            declineTrade()

            goNext = true
            releaseIncomingTradeLock()
            resetTradeState()

            continue
        end

        sendMessage(
            "Bot READY - click confirm!"
        )

        confirmFired = true
        validationRunning = false

        connectMessage(
            localId,
            method
        )

        connectStatus(
            localId,
            method
        )

        task.spawn(function()
            task.wait(TRADE_TIMEOUT_SECONDS)

            if not goNext
                and tradeId == localId
                and isInTrade()
            then
                sendMessage(
                    "Trade timed out - cancelling"
                )

                cancelWithdrawalTrade(
                    withdrawalData.data,
                    "Timed out",
                    true
                )

                sendDiscord(
                    "Withdrawal timed out: " ..
                    username,
                    16776960
                )

                declineTrade()

                goNext = true
                tradeId = 0
                lastGameTradeId = nil
                method = nil
                releaseIncomingTradeLock()
                resetTradeState()
                print("[TRADE] Withdrawal timeout cleanup complete - ready for next trade")
            end
        end)

    else
        cancelWithdrawalTrade(
            withdrawalData.data,
            "Failed to accept trade",
            true
        )

        sendMessage(
            "Failed to accept - please try again"
        )

        warn("[ACCEPT] No actual trade opened - resetting state")
        tradeId = 0
        lastGameTradeId = nil
        method = nil
        goNext = true
        releaseIncomingTradeLock()
        resetTradeState()
    end
        elseif depositAllowed then
            print("[TRADE] DEPOSIT MODE: " .. username)

            goNext = false
            method = "deposit"

            local localId = acceptTradeRequest(trade)

            tradeId = localId or 0
            lastGameTradeId = localId

            if localId then
                sendMessage("Add pets/gems then click READY")

                sendDiscord(
                    "Deposit started: " .. username,
                    3447003
                )

                connectMessage(localId, method)
                connectStatus(localId, method)

                task.spawn(function()
                    task.wait(TRADE_TIMEOUT_SECONDS)

                    if not goNext
                        and tradeId == localId
                        and isInTrade()
                    then
                        sendMessage("Deposit timed out - cancelling")

                        sendDiscord(
                            "Deposit timed out: " .. username,
                            16776960
                        )

                        declineTrade()

                        goNext = true
                        tradeId = 0
                        lastGameTradeId = nil
                        method = nil
                        releaseIncomingTradeLock()
                        resetTradeState()
                        print("[TRADE] Deposit timeout cleanup complete - ready for next trade")
                    end
                end)

            else
                sendMessage("Failed to accept - please try again")
                warn("[ACCEPT] No actual trade opened - resetting state")
                tradeId = 0
                lastGameTradeId = nil
                method = nil
                goNext = true
                releaseIncomingTradeLock()
                resetTradeState()
            end
        end
    end
end)

print("[BOT] BloxyFlip Bot RUNNING!")
print("[BOT] Handling: DEPOSITS + WITHDRAWALS")
