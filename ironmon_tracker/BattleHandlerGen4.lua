BattleHandlerGen4 = BattleHandlerBase:new()
local FrameCounter = dofile(Paths.FOLDERS.DATA_FOLDER .. "/FrameCounter.lua")

-- local targetAddressFirstPoke = 0x022629A4
-- local targetAddressOtherPokes = 0x0223D20C
-- local hookName = "JumpToPokeball"
-- local memoryDomain = "ARM9 System Bus"

-- event.on_bus_exec(
--     function(addr, val, flags)
--         print("Sent out first Poke! Execution detected at address 0x" .. string.format("%X", targetAddressFirstPoke))
--         print("Program Counter: 0x" .. string.format("%X", emu.getregister("PC")))
--         print("Address value: " .. Memory.read_u16_le(0x022629A4))
--     end,
--     targetAddressFirstPoke,
--     hookName,
--     memoryDomain
-- )

-- event.on_bus_exec(
--     function(addr, val, flags)
--         print("Sent out other Poke! Execution detected at address 0x" .. string.format("%X", targetAddressOtherPokes))
--         print("Program Counter: 0x" .. string.format("%X", emu.getregister("PC")))
--         -- Handle the flag that indicates a Pokemon has switched in
--         BattleHandlerGen4._monRecentlyDeadAwaitingNew = false -- This may not work due to weird code structure
--         print(Memory.read_u16_le(0x0223D20C))
--     end,
--     targetAddressOtherPokes,
--     hookName,
--     memoryDomain
-- )

function BattleHandlerGen4._readAbilityMessages(self)
    if not self:inBattleAndFetched() or not self.memoryAddresses.battleSubscriptMsgs then
        return
    end

    -- Check current battle message to see if it's related to an ability triggering
    local msgId = Memory.read_u16_le(self.memoryAddresses.battleSubscriptMsgs) or -1
    local knownMsg = AbilityData.BATTLE_MSGS[msgId]
    if not knownMsg then
        return
    end

    local battleMons = self:getAllPokemonInBattle()
    if battleMons == nil or next(battleMons) == nil then
        return
    end

    -- Determine what ability triggered and which pokemon triggered it (the source)
    local sourcePokemon
    local numPossibleSources = 0
    for _, pokemon in pairs(battleMons) do
        if knownMsg[pokemon.ability] then
            numPossibleSources = numPossibleSources + 1
            sourcePokemon = pokemon
        end
    end

    -- Don't track the ability if more than one pokemon may have triggered it
    -- NOTE: This is currently a necessary precaution, since there isn't a good way to determine the source of the ability
    if not sourcePokemon or numPossibleSources ~= 1 then
        return
    end

    --speed boost sanity check
    if sourcePokemon.ability == 3 and sourcePokemon.statStages["SPE"] <= 6 then
        return
    end

    self:_trackAbility(sourcePokemon.pokemonID, sourcePokemon.ability)

    -- Check if Trace(id=36) triggered in a 1v1 battle and it belongs to the player, if so track enemy ability
    if sourcePokemon.ability == 36 and #battleMons == 2 and sourcePokemon == battleMons[1] then
        self:_trackAbility(battleMons[2].pokemonID, battleMons[2].ability)
    end
end

function BattleHandlerGen4:_setUpBattleVariables()
    self:_baseSetUpBattleVariables()
end

function BattleHandlerGen4:_addBattlerSlot(battlerSlots, slot, PIDAddress)
    if slot == nil then
        slot = #battlerSlots + 1
    end
    battlerSlots[slot] = {
        activePIDAddress = PIDAddress,
        lastValidPID = -1,
        lastValidPokemon = nil,
        currentPokemon = nil,
        previousHP = -1,
        initialPID = Memory.read_u32_le(PIDAddress)
    }
end

function BattleHandlerGen4:_readTeamPIDs(battleData)
    local currentBase = battleData.partyBase
    local limit = 5
    for i = 0, limit, 1 do
        if i == 6 then
            currentBase = battleData.partyBase + self._gameInfo.ENEMY_PARTY_OFFSET
        end
        local pid = Memory.read_u32_le(currentBase)
        local checksum = Memory.read_u16_le(currentBase + 0x06)
        if checksum ~= 0 then
            battleData.battleTeamPIDs[i] = pid
        end
        currentBase = currentBase + self._gameInfo.ENCRYPTED_POKEMON_SIZE
    end
end

function BattleHandlerGen4:_readBattlePIDInfo(battleData)
    for i = 0, 1, 1 do
        local newBase = battleData.PIDBase + (i * self._gameInfo.ACTIVE_PID_DIFFERENCE)
        if (Memory.read_u32_le(newBase)) ~= 0 then
            self:_addBattlerSlot(battleData.slots, i + 1, newBase)
        end
    end
end

function BattleHandlerGen4:_tryToFetchBattleData()
    local firstPlayerPartyPID = Memory.read_u32_le(self.memoryAddresses.playerBase)
    local firstPlayerPID = Memory.read_u32_le(self.memoryAddresses.playerBattleBase)
    local firstEnemyPID = Memory.read_u32_le(self.memoryAddresses.enemyBase)
    if firstPlayerPID == 0 or firstEnemyPID == 0 or firstPlayerPID ~= firstPlayerPartyPID then
        return false
    end
    local battleData = self:getBattleData()
    for _, data in pairs(battleData) do
        self:_readTeamPIDs(data)
        self:_readBattlePIDInfo(data)
    end
    if #battleData["player"].slots == 0 or #battleData["enemy"].slots == 0 then
        battleData["player"].slots = {}
        battleData["enemy"].slots = {}
        return false
    end
    self:addFrameCounter("abilityTracking", FrameCounter(8, self._readAbilityMessages, self))
    return true
end

function BattleHandlerGen4:_getBattleMonPID(battler)
    local pidAddress = battler.activePIDAddress
    local activePID = Memory.read_u32_le(pidAddress)
    if activePID == 0 then
        return Memory.read_u32_le(pidAddress)
    else
        return activePID
    end
end

function BattleHandlerGen4:_isTransformed(battleData, activePID)
    for _, pid in pairs(battleData.battleTeamPIDs) do
        if pid == activePID then
            return false
        end
    end
    return true
end

function BattleHandlerGen4:_updateStatStages(data, slotIndex, isEnemy)
    --goes player 1, enemy 1, player 2, enemy 2
    --player 1 -> enemy 1 is a difference of C0, so we skip ahead with twice the distance to make things easier
    local statStageDifference = 2 * 0xC0
    local base = self.memoryAddresses.statStagesPlayer
    if isEnemy then
        base = self.memoryAddresses.statStagesEnemy
    end
    local statStagesAddress = base + (slotIndex - 1) * statStageDifference
    self.pokemonDataReader.setCurrentBase(statStagesAddress)
    data.statStages = self.pokemonDataReader.readBattleStatStages()
end

function BattleHandlerGen4:_getMonIndexes(battleData, pidToMatch)
    local indexes = {}
    for index, pid in pairs(battleData.battleTeamPIDs) do
        if pid == pidToMatch then
            table.insert(indexes, index)
        end
    end
    return indexes
end

function BattleHandlerGen4:_getPokemonData(battleData, slotIndex, isEnemy)
    if not self:inBattleAndFetched() then
        return
    end

    local battlers = battleData.slots
    local battler = battlers[slotIndex]
    local currentBase = battleData.partyBase
    local activePID = self:_getBattleMonPID(battler)
    local transformed = self:_isTransformed(battleData, activePID)
    if transformed then
        activePID = battler.lastValidPID
    end
    local monIndexes = self:_getMonIndexes(battleData, activePID)
    if next(monIndexes) == nil then
        return
    end
    local data
    for _, monIndex in pairs(monIndexes) do
        local base = currentBase + monIndex * self._gameInfo.ENCRYPTED_POKEMON_SIZE
        self.pokemonDataReader.setCurrentBase(base)
        local check = self.pokemonDataReader.decryptPokemonInfo(false, monIndex, isEnemy)
        if check ~= nil and next(check) ~= nil then
            if not isEnemy then
                data = check
            elseif (#battlers > 1) or (check.pokemonID and check.pokemonID == Memory.read_u16_le(self.memoryAddresses.enemyPokemonID)) then
                data = check
            end
        end
    end
    if data == nil then
        return battler.lastValidPokemon
    end
    self:_updateStatStages(data, slotIndex, isEnemy)
    self._program.checkForAlternateForm(data)
    if activePID ~= battler.lastValidPID and isEnemy then
        self:_logNewEnemy(data)
        if battler.lastValidPokemon ~= nil then
            self._tracker.updateLastLevelSeen(battler.lastValidPokemon.pokemonID, battler.lastValidPokemon.level)
        end
        battler.lastValidPokemon = data
    end
    battler.lastValidPID = activePID
    return data
end

---Returns true if it's okay to read battle data
---@return boolean
function BattleHandlerGen4:canReadData()
	-- Don't allow reading new battle data if a Pokemon recently died; wait until a new mon is sent out
	return not self._monRecentlyDeadAwaitingNew
end

function BattleHandlerGen4:updateFlags()
	-- Don't bother updating if not in a battle
	if not self:isInBattle() then
		return
	end

	-- Flags for a Pokemon dying recently and before a new Pokemon is sent out to replace it
	if not self._monRecentlyDeadAwaitingNew then
		-- After a mon dies, prevent data reads until mons get sent out
		local msgId = Memory.read_u16_le(self.memoryAddresses.battleSubscriptMsgs) or -1
		if msgId == 6 then -- 6: special value for any mon dying
			--print(string.format("[DEBUG] Mon recently died!"))
			self._monRecentlyDeadAwaitingNew = true
		end
	else
		-- When a [real] condition is met to automatically unblock the data read, clear the flag to allow data again
        local sentOutMsgId = Memory.read_u16_le(self.memoryAddresses.enemySentOutMsg) or -1
		if sentOutMsgId == 0x4d7c then
			self._monRecentlyDeadAwaitingNew = false
		end
	end
end
