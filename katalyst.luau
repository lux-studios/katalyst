-- General-purpose instance framework
-- https://github.com/lux-studios/katalyst

-- Copyright (c) 2026 Lux Studios

-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

local katalyst = {}

local updateQueue = {}
local scheduleThread: thread?

local function flushUpdates()
	scheduleThread = nil
	
	local toUpdate = updateQueue
	updateQueue = {}
	
	local function catch(err)
		warn(debug.traceback(string.format("Error in batched update: %s", tostring(err)), 2))
	end
	
	for fn in next, toUpdate do
		xpcall(fn, catch)
	end
end

local function scheduleUpdate(fn)
	updateQueue[fn] = true
	if not scheduleThread then
		scheduleThread = task.defer(flushUpdates)
	end
end

local function createSignal()
	local listeners: {() -> ()} = {}
	
	local function connect(_, fn)
		table.insert(listeners, fn)
		
		local function disconnect()
			local index = table.find(listeners, fn)
			if index then
				table.remove(listeners, index)
			end
		end
		
		return {Disconnect = disconnect, disconnect = disconnect}
	end
	
	local function fire(_, ...)
		for _, fn in next, listeners do
			fn(...)
		end
	end
	
	return {
		Connect = connect, connect = connect,
		Fire = fire, fire = fire,
	}
end

export type StateObject<T> = {
	_value: T,
	_changed: any,
	get: (StateObject<T>) -> T,
	set: (StateObject<T>, val: T) -> (),
	onChange: (StateObject<T>, fn: (T) -> ()) -> any,
	destroy: (StateObject<T>) -> (),
}
export type State<T> = StateObject<T>

local stateCleanupRegistry = setmetatable({}, {__mode = "k"})

local function isState(obj: any): boolean
	return stateCleanupRegistry[obj] == true
end

local function impl_state<T>(initial: T): State<T>
	local stateObj = {
		_value = initial,
		_changed = createSignal()
	}
	
	function stateObj:get(): T
		return self._value
	end
	
	function stateObj:set(val: T)
		local oldValue = self._value
		
		if oldValue == val then
			return
		end
		
		if type(oldValue) == "table" and type(val) == "table" then
			local function deepEquals(a, b)
				if a == b then return true end
				if typeof(a) ~= typeof(b) then return false end
				if type(a) ~= "table" then return false end
				
				for k, v in next, a do
					if not deepEquals(v, b[k]) then
						return false
					end
				end
				
				for k in next, b do
					if a[k] == nil then
						return false
					end
				end
				
				return true
			end
			
			if deepEquals(oldValue, val) then
				return
			end
		end
		
		self._value = val
		scheduleUpdate(function()
			self._changed:Fire(val)
		end)
	end
	
	function stateObj:onChange(fn)
		return self._changed:Connect(fn)
	end
	
	function stateObj:destroy()
		if self._changed then
			-- Disconnect all listeners and reset signal
			self._changed = createSignal()
		end
		stateCleanupRegistry[self] = nil
	end
	
	-- Register for cleanup tracking
	stateCleanupRegistry[stateObj] = true
	
	return (stateObj :: any) :: State<T>
end

katalyst.State = impl_state

export type ReactiveValue = string | number | boolean | Color3 | UDim2 | Vector2 | Rect | BrickColor | EnumItem | {[any]: any}
export type ReactiveProp<R = ReactiveValue> = R | State<R> | (() -> R)

export type Proxy<I> = (() -> I) & I

export type PropertyTable<I = Instance> = {
	[string]: ReactiveProp<any>?,
	Children: {Instance | {Instance} }?,
	Ref: ((self: Proxy<I>) -> (() -> ())?)?,
}

export type NewConstructor = ((className: string) -> (props: PropertyTable) -> Proxy<Instance>)

local proxyRegistry = setmetatable({}, {__mode = "k"})
local childCache = setmetatable({}, {__mode = "k"})
local childCleanupConnections = setmetatable({}, {__mode = "k"})

local function updateChildren(parent: Instance, newChildren: {any})
	local cache = childCache[parent] or {}
	local used = {}
	
	local function recurse(newChildren: {any})
		for i, child in next, newChildren do
			local inst
			if proxyRegistry[child] then
				inst = child()
			elseif type(child) == "table" and #child > 0 then
				recurse(child)
			elseif typeof(child) == "Instance" then
				inst = child
			end
			
			if inst then
				if inst.Parent ~= parent then
					inst.Parent = parent
				end
				used[inst] = true
			end
		end
	end
	
	recurse(newChildren)
	
	for inst in next, cache do
		if not used[inst] then
			inst.Parent = nil
		end
	end
	
	childCache[parent] = used
	
	-- Setup cleanup for parent destruction
	if not childCleanupConnections[parent] then
		childCleanupConnections[parent] = parent.Destroying:Connect(function()
			childCache[parent] = nil
			childCleanupConnections[parent] = nil
		end)
	end
end

local function impl_new(className: string)
	return function(props: PropertyTable<any>)
		local instance = Instance.new(className)
		local stateConnections: {[string]: any} = {}
		
		-- children reactivity
		local function applyChildren(val: any)
			if type(val) == "function" then
				updateChildren(instance, val() or {})
			elseif isState(val) then
				updateChildren(instance, val:get() or {})
				val:onChange(function(newVal)
					updateChildren(instance, newVal or {})
				end)
			elseif val then
				updateChildren(instance, val)
			end
		end
		
		-- proxy wrapper
		local proxy = {}
		setmetatable(proxy, table.freeze {
			__index = function(_, k)
				local member = instance[k]
				if type(member) == "function" then
					return function(self, ...)
						if self == proxy then
							self = instance
						end
						return member(self, ...)
					end
				end
				return member
			end,
			
			__newindex = function(_, k, v)
				if isState(v) then
					instance[k] = v:get()
					if stateConnections[k] then
						stateConnections[k]:Disconnect()
					end
					stateConnections[k] = v:onChange(function(newVal)
						instance[k] = newVal
					end)
				elseif type(v) == "function" and k ~= katalyst.Children then
					local result = v()
					instance[k] = result
				elseif k == katalyst.Children then
					applyChildren(v)
				else
					instance[k] = v
				end
			end,
			
			__tostring = function()
				return instance:GetFullName()
			end,
			
			__eq = function(_, other)
				return rawequal(other, instance) or rawequal(other, proxy)
			end,
			
			__call = function()
				return instance
			end,
			
			__metatable = "This metatable is locked"
		})
		
		proxyRegistry[proxy] = true
		
		for k, v in next, props do
			if k == katalyst.Ref then
				continue
			else
				proxy[k] = v
			end
		end
		
		local ref = props[katalyst.Ref]
		if type(ref) == "function" then
			task.defer(function()
				local cleanup = ref(proxy)
				if cleanup then
					instance.Destroying:Connect(cleanup)
				end
			end)
		end
		
		instance.Destroying:Once(function()
			for _, conn in next, stateConnections do
				conn:Disconnect()
			end
			table.clear(stateConnections)
		end)
		
		return (proxy :: any) :: Proxy<any>
	end
end

local function impl_errorBoundary(fallbackComponent)
	return function(component)
		return function(props)
			local _, result = xpcall(component, function(err)
				warn("katalyst:", "component error:", err)
				local result = debug.traceback(err, 2)
				
				if fallbackComponent then
					return fallbackComponent(props, result)
				end
				
				return nil
			end, props)
			
			return result
		end
	end
end

function katalyst.Fragment(render: () -> {Instance}): {Instance}
	return render()
end

function katalyst.Map<T>(array: {T}, render: (item: T, index: number) -> Instance)
	local results = {}
	for i, item in next, array do
		local child = render(item, i)
		results[i] = child
	end
	return results
end

function katalyst.Unwrap<T>(value: Proxy<T> | State<T>): any
	if isState(value) then
		return value:get()
	elseif proxyRegistry[value] then
		return value()
	end
	return value
end

katalyst.New = (impl_new :: any) :: NewConstructor
katalyst.ErrorBoundary = impl_errorBoundary

katalyst.Children = newproxy()
katalyst.Ref = newproxy()

katalyst.new = katalyst.New
katalyst.map = katalyst.Map
katalyst.state = katalyst.State
katalyst.fragment = katalyst.Fragment
katalyst.errorBoundary = katalyst.ErrorBoundary
katalyst.unwrap = katalyst.Unwrap
katalyst.children = katalyst.Children
katalyst.ref = katalyst.Ref

return table.freeze(katalyst)