--everything here belongs to https://github.com/NeonD00m/feces

--!strict
--!optimize 2
--[=[
	@class feces
	The feces library for replicating jecs entities and components.
]=]
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local isClient = RunService:IsClient()
local jecs = require(ReplicatedStorage.packages.jecs)

local pair = jecs.pair
local __ = jecs.Wildcard

type Entity = jecs.Entity & number
type Component<T = any> = jecs.Entity<T> & number

type nilValue = "__n"
local NIL_VALUE: nilValue = "__n"

type deleteValue = "__d"
local DELETE_VALUE: deleteValue = "__d"

type PlayerObject = Player? | { Player } | (Player) -> boolean

--[=[ 
	@within feces
	@type changes { [Component]: { [Player]: { value: { [Entity]: any }, special: { [Entity]: deleteValue | nilValue } } } }
	How changes are represented and returned from [`delta()`](/api/feces#delta).
]=]
type changes = {
	[Component]: {
		[Player]: {
			value: { [Entity]: any },
			special: { [Entity]: deleteValue | nilValue }
		}
	}
}
--[=[
	@type deletes { [Player]: { Entity } }
	@within feces
	How deleted entities are represented.
]=]
type deletes = {
	[Player]: { Entity }
}
--[=[
	@type applyable { [Component]: { value: { [Entity]: any }, special: { [Entity]: deleteValue | nilValue } } } & { __d: { Entity } }
	@within feces
	Funkier type for how applyable changes should be formated.
]=]
type applyable = {
	[Component]: {
		value: { [Entity]: any },
		special: { [Entity]: deleteValue | nilValue }
	}
} & { __d: { Entity }}

export type lib = {
	new: (jecs.World, jecs.Id) -> feces,
	group: (changes, deletes?) -> { [Player]: applyable },
}

export type feces = lib & {
	queries: {
		single: jecs.Query,
		pair: jecs.Query,
	},
	world: jecs.World,
	pendingChanges: changes,
	pendingDeletes: deletes,
	refs: { [string]: Entity },

	ref: (self: feces, key: string?) -> Entity,
	replicating: (self: feces, (Component, PlayerObject, Entity, any, Component) -> nil) -> nil,

	apply: (self: feces, applyable) -> nil, -- applies component changes to world
	delta: (self: feces) -> (changes, deletes), -- gets the component changes to replicate

	-- gets the entity deletions to replicate
	full: (self: feces) -> applyable, -- gets all currently replicating components
	group: (changes, deletes?) -> { [Player]: applyable },
	
	-- hooks into applying replication
	added: (self: feces, (Entity) -> nil) -> nil,
	changed: (self: feces, (Entity, Component, any) -> nil) -> nil,
	removed: (self: feces, (Entity, Component) -> nil) -> nil,
	deleted: (self: feces, (Entity) -> nil) -> nil,
    hooks: {
        added: ((Entity) -> nil)?,
	    changed: ((Entity, Component, any) -> nil)?,
	    removed: ((Entity, Component) -> nil)?,
	    deleted: ((Entity) -> nil)?
    }
}

local lib = {}

local availablePlayers = {}
local playerConnections = {}

local function getPlayers(info: PlayerObject): { Player? }
	if typeof(info) == "table" then
		return info
	elseif typeof(info) == "function" then
		local result = {}
		for key, player in Players:GetPlayers() do
			if not info(player) then
				continue
			end
			
			result[key] = player
		end
		return result
	end
	
	return if typeof(info) == "Instance" and info:IsA("Player") then { info } else availablePlayers
end

local function fill(changes: changes, comp: Component, ent: Entity, value: any, players: { Player? })
	changes[comp] = changes[comp] or {}
	for _, player in players do
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			continue
		end

		changes[comp][player] = changes[comp][player] or { value = {}, special = {} }
		if value == DELETE_VALUE or value == NIL_VALUE then
			changes[comp][player].special[ent] = value
		else
			changes[comp][player].value[ent] = value
		end
	end
end

local function ref(self: feces, key: string?): Entity
	local world = self.world
	if not key then
		return world:entity()
	end

	local refs = self.refs
	local entity = refs[key]
	if not entity then
		entity = world:entity()
		refs[key] = entity
	end
	
	return entity
end

local function replicating(self: feces, callback: (Component, PlayerObject, Entity, any, Component) -> nil)
	for _, archetype in self.queries.single:archetypes() do
		local entities = archetype.entities
		local columns = archetype.columns
		local types = archetype.types
		local record = archetype.records[self.replicated]
		if not record then
			continue
		end
		
		local playerColumn = columns[record]
		for key, id in types do
			if id == self.replicated :: number then
				continue
			end
			local column = columns[key]
			if not column then
				continue
			end

			for row, entity in entities do
				local player = playerColumn[row]
				callback(
					id :: Component,
					player,
					entity :: Entity,
					column[row],
					self.replicated
				)
			end
		end
	end

	for _, archetype in self.queries.pair:archetypes() do
		local entities: { number } = archetype.entities
		local types = archetype.types
		local records = archetype.records

		for _, id in types do
			if not jecs.IS_PAIR(id) then
				continue
			end

			if jecs.pair_first(self.world, id) ~= self.replicated :: number then
				continue -- it's a pair but the first component isn't replicated e.g pair(someComponent, someOtherComponent) instead of pair(replicated, someOtherComponent)
			end

			local record = records[id]
			if not record then
				continue
			end

			local playerColumn = archetype.columns[record]
			local component = jecs.pair_second(self.world, id)
			for row, entity in entities do
				if not self.world:has(entity :: Entity, component :: Component) then
					continue
				end

				callback(
					component :: Component,
					playerColumn[row],
					entity :: Entity,
					self.world:get(
						entity :: Entity,
						component :: Component
					),
					id :: Component
				)
			end
		end
	end
end
--[=[
	@within feces
	Applies changes to the world by taking in the [`applyable`](/api/feces#applyable) type and editing the world. 
	```lua
	feces:apply({
		[someComponent] = {
			[someForeignEntity] = someValue,
		}
	})
	```
]=]
local function apply(self: feces,delta: applyable)
	if not delta then
		warn("NO APPLYABLE DATA RECEIVED")
		return
	end

	for component, entities in delta :: {[any]: any } do
		if not entities then
			continue
		end
		
		if component == DELETE_VALUE then
			for _, entity in entities do
				local id = self:ref(`repl{entity}`)
				if self.hooks.deleted then
					self.hooks.deleted(id)
				end
				self.world:delete(id)
			end
			continue
		end
		
		local newEntities = {}

		for entity: Entity, value in entities.value do
			if not self.refs[`repl{entity}`] then
				local id = self:ref(`repl{entity}`)
				if self.hooks.changed then
					self.hooks.changed(id, component, value)
				end
				self.world:set(id, component, value)
				if self.hooks.added then
					newEntities[id] = true
				end
			else
				local id = self:ref(`repl{entity}`)
				if self.hooks.changed then
					self.hooks.changed(id, component, value)
				end
				self.world:set(id, component, value)
			end
		end

		for entity: Entity, value in entities.special do
			local id = self:ref(`repl{entity}`)

			if value == DELETE_VALUE then
				if self.hooks.removed then
					self.hooks.removed(id, component)
				end
				self.world:remove(id, component)
				continue
			end
			
			local newValue = if value == NIL_VALUE then nil else value
			if self.hooks.changed then
				self.hooks.changed(id, component, newValue)
			end

			self.world:set(id, component, newValue)
		end

		if self.hooks.added then
			for id, _ in newEntities do
				self.hooks.added(id)
			end
		end
	end
end
--[=[
	@within feces
	Gets the world changes from the last time it was called.
	```lua
	local changedComponents, deletedEntities = feces:delta()
	-- ... replicate however you'd like or see the examples [here](/docs/setup)
	```
]=]
local function delta(self: feces): (changes, deletes)
	local changes: changes, deleted: deletes = self.pendingChanges, self.pendingDeletes
	
	self.pendingChanges, self.pendingDeletes = {}, {}
	
	return changes, deleted
end
--[=[
	@within feces
	Reformats the results of [`delta()`](/api/feces#delta) into an easier format to replicate.
	Not optimal, but recommended if performance of feces-replicated entities is not a concern.
	```lua
	local dataByPlayer = feces.group(feces:delta())
	for player, packet in dataByPlayer do
		someRemote:FireClient(player, packet)
	end
	-- see more of this example [here](/docs/setup#simple)
	```
]=]
local function group(changes: changes, deleted: deletes?): { [Player]: applyable }
	local packets: { [Player]: applyable } = {}

	for component, players in changes do
		for player, entities in players do
			packets[player] = packets[player] or {__d = {}}
			packets[player][component] = packets[player][component] or { value = {}, special = {} }
			for entity, value in entities.value do
				(packets[player][component] :: any).value[entity] = value
			end
			for entity, value in entities.special do
				(packets[player][component] :: any).special[entity] = value
			end
		end
	end

	if deleted then
		for player, entities in deleted do
			packets[player] = packets[player] or {__d = {}}
			packets[player].__d = entities
		end
	end
	
	return packets
end
lib.group = group
--[=[
	@within feces
	Gets all the currently replicating component and entity values.
	:::tip
	This is useful for providing payloads to new players when they first join a server.
	:::
	```lua
	local changedComponents = feces:full()
	-- ... replicate however you'd like or see the examples [here](/docs/setup)
	```
]=]
local function full(self: feces): applyable
	local data = {} :: applyable

	self:replicating(function(component, player, entity, value)
		if player then
			return -- we only want publicly replicated data
		end
		data[component] = data[component] or { value = {}, special = {} }
		if value == DELETE_VALUE or value == NIL_VALUE then
			(data[component].special :: any)[entity] = value
		else
			(data[component].value :: any)[entity] = value
		end
	end)

	return data
end
--[=[
	@within feces
	Adds a callback for when an entity is added to the world through [`apply()`](/api/feces#apply).
	Called *after* **a** (not all) component value is set to a newly replicated entity.
	See how you might use this [here](/docs/hooks#added).
]=]
local function added(self: feces, callback: (Entity) -> nil)
	self.hooks.added = callback
end
--[=[
	@within feces
	Adds a callback for when a component value is changed in the world through [`apply()`](/api/feces#apply).  
	Called *before* the component in question is changed, deleted, or set to `nil`.
	See how you might use this [here](/docs/hooks#changed).
]=]
local function changed(self: feces, callback: (Entity, Component, any) -> nil)
	self.hooks.changed = callback
end
--[=[
	@within feces
	Adds a callback for when a component is removed in the world through [`apply()`](/api/feces#apply).   
	Called *before* the component in question is removed.
	See how you might use this [here](/docs/hooks#removed).
]=]
local function removed(self: feces, callback: (Entity, Component) -> nil)
	self.hooks.removed = callback
end
--[=[
	@within feces
	Adds a callback for when an entity is deleted in the world through [`apply()`](/api/feces#apply).   
	Called *before* the entity in question is deleted, allowing hooks to get component values and clean up.
	See how you might use this [here](/docs/hooks#deleted).
]=]
local function deleted(self: feces, callback: (Entity) -> nil)
	self.hooks.deleted = callback
end

-- MEGA SU
-- convert class structure to axis-like and skilift-like
-- use component_index to get every registered component in the world and check metatables for when to check if theres a new component
-- listen to when a component is added, removed and changed via observers and propagate that further into replication
-- get replication changes
-- REPLICATE THE DATA!!!
-- receive the data...
-- APPLY THE DATAA!!!
-- make sure that EVERYTHING works!!!! SUPER Important



function lib.new(world: jecs.World, replicated: jecs.Id): feces
	--assume the user has already added observers to the world
    local self = {
		replicated = replicated,
		queries = {
			single = world:query(replicated):cached(),
			pair = world:query(pair(replicated, __)):cached(),
		},
        world = world,
        pendingChanges = {} :: changes,
        pendingDeletes = {} :: deletes,
        hooks = {},
		refs = {},
		ref = ref,
		replicating = replicating,
		apply = apply,
		delta = delta,
		full = full,
		group = group,
		added = added,
		changed = changed,
		removed = removed,
		deleted = deleted,
    } :: any
	if isClient then
		return self :: feces
	end

	if next(playerConnections) == nil then
		availablePlayers = Players:GetPlayers()
		table.insert(playerConnections, Players.PlayerAdded:Connect(function(player: Player)
			availablePlayers[`{player.UserId}`]  = player
		end))

		table.insert(playerConnections, Players.PlayerRemoving:Connect(function(player: Player)
			availablePlayers[`{player.UserId}`] = nil
		end))
	end

	local function fillChanges(entity, value, component)
		local record = jecs.entity_index_try_get_fast(world.entity_index, entity)
		if not record then
			return
		end
	
		local archetype = record.archetype
		if not archetype then
			return
		end		

		local players = getPlayers(archetype.records[replicated])
		fill(self.pendingChanges, component, entity, if value == DELETE_VALUE then DELETE_VALUE elseif value == nil then NIL_VALUE else value, players :: { Player })
	end

	local function listen(component)
		local paired = pair(replicated, component)

		world:added(component, function(entity, id, value)
			fillChanges(entity, value, component)
		end)

		world:changed(component, function(entity, id, value)
			fillChanges(entity, value, component)
		end)

		world:removed(component, function(entity, id)
			fillChanges(entity, DELETE_VALUE, component)
		end)
	
		world:added(paired, function(entity, id, value)
			fill(
				self.pendingChanges,
				component, entity,
				world:get(entity, component),
				getPlayers(value) :: { Player }
			)
		end)
	
		world:removed(paired, function(entity, value)
			fill(self.pendingChanges, component, entity, DELETE_VALUE, getPlayers(value))
		end)
	end

	local function disconnect(component)
		local paired = pair(replicated, component)
		local signals = world.signals
		signals.added[component] = nil
		signals.emplaced[component] = nil
		signals.removed[component] = nil

		signals.added[paired] = nil
		signals.emplaced[paired] = nil
		signals.removed[paired] = nil
	end

	local component_index = world.component_index
	for component in component_index do
		if component == replicated or (jecs.IS_PAIR(component) and jecs.pair_first(world, component) == replicated) then
			continue
		end

		listen(component)
	end

	setmetatable(component_index, {
		__newindex = function(tbl, component, value)
			if component == replicated or (jecs.IS_PAIR(component) and jecs.pair_first(world, component) == replicated) then
				rawset(tbl, component, value)
				return
			end

			local old = rawget(tbl, component)
			rawset(tbl, component, value)

			if old == nil and value ~= nil then
				listen(component)
			elseif old ~= nil and value == nil then
				disconnect(component)
			end
		end,
		__index = function(tbl, key)
			return rawget(tbl, key)
		end
	})

    world:added(replicated, function(entity, value: PlayerObject)
		local record = jecs.entity_index_try_get_fast(world.entity_index, entity)
		if not record then
			return
		end

		local archetype = record.archetype
		if not archetype then
			return
		end

		local columns = archetype.columns
		local row = record.row
		local types = archetype.types
        local players = getPlayers(value)

		for key, id in types do
			if id == replicated then
				continue
			end

			local column = columns[key]
			if not column then
				continue
			end

			fill(self.pendingChanges, id, entity, column[row], players)
		end
    end)

    world:removed(replicated, function(entity, value)
        for _, player in getPlayers(value) do
            if not player then 
				continue 
			end

			local deleted = self.pendingDeletes[player]
			if not deleted then
				deleted = {}
				self.pendingDeletes[player] = deleted
			end
            table.insert(deleted, entity)
        end
    end)

    return self :: feces
end

return lib :: lib