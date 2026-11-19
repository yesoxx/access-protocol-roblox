-- Discord: yesofr | Roblox: YoyoWasAndIsTheBest
--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

type State = "Closed" | "Opening" | "Open" | "Closing" | "Locked"
type Door = {
	model: Model, panel: BasePart, reader: BasePart, light: BasePart,
	prompt: ProximityPrompt, closed: CFrame, opened: CFrame,
	level: number, seconds: number, duration: number, state: State,
	serial: number, alive: boolean, tween: Tween?, completion: RBXScriptConnection?,
	connections: {RBXScriptConnection}, cooldown: {[Player]: number},
	closeTask: thread?, denialTask: thread?,
}
type Watch = {connections: {RBXScriptConnection}, partConnections: {RBXScriptConnection}, panel: BasePart?, closed: CFrame?, queued: boolean}
type Session = {level: number, nextAction: number, connections: {RBXScriptConnection}}

local TAG = "AccessProtocolDoor"
local doors: {[Instance]: Door} = {}
local watched: {[Instance]: Watch} = {}
local sessions: {[Player]: Session} = {}
local connections: {RBXScriptConnection} = {}
local lockdown = false
local running = true
local GREEN = Color3.fromRGB(65, 225, 151)
local YELLOW = Color3.fromRGB(255, 195, 70)
local RED = Color3.fromRGB(255, 76, 93)

-- Display Attributes are observable diagnostics; only these private tables grant authority.
local function updateCounts(): ()
	local active, tracked = 0, 0
	for _ in doors do active += 1 end
	for _ in watched do tracked += 1 end
	script:SetAttribute("RegisteredDoorCount", active)
	script:SetAttribute("WatchedDoorCount", tracked)
end

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function cancelTimer(handle: thread?): ()
	if handle and coroutine.status(handle) == "suspended" then task.cancel(handle) end
end

local function disconnectAll(list: {RBXScriptConnection}): ()
	for _, connection in list do
		connection:Disconnect()
	end
	table.clear(list)
end

local function numberAttribute(instance: Instance, name: string, default: number, low: number, high: number): number
	local value = instance:GetAttribute(name)
	if typeof(value) ~= "number" or not finite(value) then
		return default
	end
	return math.clamp(value, low, high)
end

local function label(part: BasePart): TextLabel?
	local gui = part:FindFirstChildWhichIsA("SurfaceGui")
	return if gui then gui:FindFirstChildWhichIsA("TextLabel") else nil
end

local function setState(door: Door, state: State): ()
	door.state = state
	door.model:SetAttribute("State", state)
	local color = if state == "Locked" then RED elseif state == "Opening" or state == "Closing" then YELLOW else GREEN
	door.light.Color = color
	local text = label(door.reader)
	if text then
		text.Text = string.format("LEVEL %d\n%s", door.level, string.upper(state))
		text.TextColor3 = color
	end
	door.prompt.ActionText = if state == "Locked" then "Locked" else "Request access"
end

local function nearAlivePlayer(player: Player, part: BasePart, range: number): boolean
	if not running or player.Parent ~= Players or not part:IsDescendantOf(Workspace) then
		return false
	end
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	local humanoid = if character then character:FindFirstChildWhichIsA("Humanoid") else nil
	-- Prompt visibility is client-side. Recheck life and distance on the server.
	return root ~= nil and root:IsA("BasePart") and humanoid ~= nil
		and humanoid.Health > 0 and (root.Position - part.Position).Magnitude <= range
end

local function feedback(player: Player, message: string): ()
	local gui = player:FindFirstChild("PlayerGui")
	local hud = if gui then gui:FindFirstChild("AccessProtocolHUD") else nil
	local text = if hud then hud:FindFirstChild("Status") else nil
	if text and text:IsA("TextLabel") then
		text.Text = message
	end
end

local function showClearance(player: Player): ()
	local session = sessions[player]
	if session then
		player:SetAttribute("DemoClearance", session.level)
		feedback(player, string.format("YOUR CLEARANCE: %d  |  %s", session.level, if lockdown then "LOCKDOWN" else "NORMAL"))
	end
end

local moveDoor: (Door, boolean) -> ()

moveDoor = function(door: Door, opening: boolean): ()
	if not door.alive then return end
	-- Increment before cancellation: stale completion/timer callbacks lose ownership.
	-- Disconnect first because Cancel itself fires Completed with Cancelled status.
	door.serial += 1
	local serial = door.serial
	cancelTimer(door.closeTask)
	cancelTimer(door.denialTask)
	door.closeTask, door.denialTask = nil, nil
	if door.completion then
		door.completion:Disconnect()
		door.completion = nil
	end
	if door.tween then
		door.tween:Cancel()
		door.tween = nil
	end
	setState(door, if opening then "Opening" else "Closing")
	local tween = TweenService:Create(door.panel,
		TweenInfo.new(door.duration, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
		{CFrame = if opening then door.opened else door.closed})
	door.tween = tween
	-- Once disconnects on invocation; the callback also checks lifetime and ownership.
	door.completion = tween.Completed:Once(function(status: Enum.PlaybackState): ()
		if not door.alive or serial ~= door.serial or status ~= Enum.PlaybackState.Completed then
			return
		end
		door.tween = nil
		door.completion = nil
		setState(door, if opening then "Open" elseif lockdown and door.level > 0 then "Locked" else "Closed")
		if opening then
			door.closeTask = task.delay(door.seconds, function(): ()
				door.closeTask = nil
				if door.alive and door.serial == serial and door.state == "Open" then
					moveDoor(door, false)
				end
			end)
		end
	end)
	tween:Play()
end

local function requestAccess(door: Door, player: Player): ()
	-- Enabled and ancestry must be enforced on the server, including detached readers.
	if not door.alive or not door.prompt.Enabled or door.prompt.Parent ~= door.reader
		or not nearAlivePlayer(player, door.reader, door.prompt.MaxActivationDistance + 1) then
		return
	end
	local now = os.clock()
	if now < (door.cooldown[player] or 0) then
		return
	end
	door.cooldown[player] = now + 0.6
	local session = sessions[player]
	if not session then
		return
	end
	if lockdown and door.level > 0 then
		feedback(player, "ACCESS DENIED: facility lockdown")
		return
	end
	if session.level < door.level then
		feedback(player, string.format("ACCESS DENIED: level %d required", door.level))
		local serial = door.serial
		door.light.Color = RED
		-- Coalesce flashes per door instead of allocating one timer for every player.
		cancelTimer(door.denialTask)
		door.denialTask = task.delay(0.8, function(): ()
			door.denialTask = nil
			if door.alive and door.serial == serial then
				setState(door, door.state)
			end
		end)
		return
	end
	-- Busy or open doors ignore repeated requests; only one transition owns CFrame.
	if door.state == "Closed" then
		feedback(player, "ACCESS GRANTED")
		moveDoor(door, true)
	end
end

local function removeDoor(instance: Instance): ()
	local door = doors[instance]
	if not door then
		return
	end
	door.alive = false
	door.serial += 1
	cancelTimer(door.closeTask)
	cancelTimer(door.denialTask)
	if door.completion then
		door.completion:Disconnect()
	end
	if door.tween then
		door.tween:Cancel()
	end
	disconnectAll(door.connections)
	table.clear(door.cooldown)
	-- Restoring the known pose makes re-tagging/reparenting deterministic mid-tween.
	if door.panel.Parent then door.panel.CFrame = door.closed end
	door.model:SetAttribute("State", "Locked")
	doors[instance] = nil
	updateCounts()
end

local function invalidConfig(instance: Model, reason: string): ()
	instance:SetAttribute("ConfigError", reason)
	instance:SetAttribute("State", "Locked")
end

local function registerDoor(instance: Instance): ()
	local watch = watched[instance]
	if not running or not watch or doors[instance] or not instance:IsA("Model") or not instance:IsDescendantOf(Workspace) then
		return
	end
	local panel = instance:FindFirstChild("Panel")
	local reader = instance:FindFirstChild("Reader")
	local light = instance:FindFirstChild("Indicator")
	local prompt = if reader then reader:FindFirstChildWhichIsA("ProximityPrompt") else nil
	if not panel or not panel:IsA("BasePart") or not reader or not reader:IsA("BasePart")
		or not light or not light:IsA("BasePart") or not prompt or not panel.Anchored
		or not reader.Anchored or not light.Anchored then
		invalidConfig(instance, "Anchored Panel, Reader, Indicator and reader prompt required")
		return
	end
	local offset = instance:GetAttribute("OpenOffset")
	local translation = if typeof(offset) == "Vector3" then offset else Vector3.new(0, 10, 0)
	local level = instance:GetAttribute("RequiredLevel")
	if level == nil then level = 0 end
	-- Invalid permission data fails closed; it must never silently become public access.
	if typeof(level) ~= "number" or not finite(level) or level % 1 ~= 0 or level < 0 or level > 2 then
		invalidConfig(instance, "RequiredLevel must be an integer from 0 to 2")
		return
	end
	if (offset ~= nil and typeof(offset) ~= "Vector3") or not finite(translation.X)
		or not finite(translation.Y) or not finite(translation.Z) or translation.Magnitude > 1000 then
		invalidConfig(instance, "OpenOffset must be finite and at most 1000 studs")
		return
	end
	if watch.panel ~= panel or not watch.closed then
		watch.panel, watch.closed = panel, panel.CFrame
	end
	local closed = watch.closed :: CFrame
	for _, component in {closed:GetComponents()} do
		if not finite(component) then
			invalidConfig(instance, "Closed pose must be finite")
			return
		end
	end
	panel.CFrame = closed
	instance:SetAttribute("ConfigError", nil)
	local door: Door = {
		model = instance, panel = panel, reader = reader, light = light, prompt = prompt,
		-- Multiply on the right so a rotated model still opens in its own axes.
		closed = closed, opened = closed * CFrame.new(translation),
		level = level,
		seconds = numberAttribute(instance, "AutoCloseSeconds", 4, 1, 30),
		duration = numberAttribute(instance, "TweenSeconds", 0.8, 0.1, 5),
		state = "Closed", serial = 0, alive = true, tween = nil, completion = nil,
		connections = {}, cooldown = {},
		closeTask = nil, denialTask = nil,
	}
	doors[instance] = door
	setState(door, if lockdown and door.level > 0 then "Locked" else "Closed")
	table.insert(door.connections, prompt.Triggered:Connect(function(player: Player): ()
		requestAccess(door, player)
	end))
	updateCounts()
end

local function unwatchDoor(instance: Instance): ()
	removeDoor(instance)
	local watch = watched[instance]
	if watch then
		disconnectAll(watch.connections)
		disconnectAll(watch.partConnections)
	end
	watched[instance] = nil
	updateCounts()
end

local function watchDoor(instance: Instance): ()
	if watched[instance] or not instance:IsA("Model") then return end
	local watch: Watch = {connections = {}, partConnections = {}, panel = nil, closed = nil, queued = false}
	watched[instance] = watch
	-- A tagged model's lifetime is distinct from its active Workspace registration.
	-- Keep one observer while in ServerStorage; release it only on untag/destruction.
	local function refresh(): ()
		if watch.queued then return end
		watch.queued = true
		task.defer(function(): ()
			watch.queued = false
			if running and watched[instance] == watch then
				-- Contract-breaking events already invalidate synchronously. Decoration
				-- additions only refresh observers; they must not interrupt a valid tween.
				disconnectAll(watch.partConnections)
				for _, name in {"Panel", "Reader", "Indicator"} do
					local part = instance:FindFirstChild(name)
					if part and part:IsA("BasePart") then
						table.insert(watch.partConnections, part:GetPropertyChangedSignal("Anchored"):Connect(function(): ()
							removeDoor(instance)
							refresh()
						end))
					end
				end
				registerDoor(instance)
			end
		end)
	end
	table.insert(watch.connections, instance.AncestryChanged:Connect(function(): ()
		removeDoor(instance)
		refresh()
	end))
	table.insert(watch.connections, instance.DescendantAdded:Connect(refresh))
	table.insert(watch.connections, instance.DescendantRemoving:Connect(function(child: Instance): ()
		local door = doors[instance]
		if door and (child == door.panel or child == door.reader or child == door.light or child == door.prompt) then
			removeDoor(instance)
		end
		refresh()
	end))
	table.insert(watch.connections, instance.AttributeChanged:Connect(function(name: string): ()
		if name == "RequiredLevel" or name == "OpenOffset" or name == "AutoCloseSeconds" or name == "TweenSeconds" then
			removeDoor(instance)
			refresh()
		end
	end))
	table.insert(watch.connections, instance.Destroying:Connect(function(): () unwatchDoor(instance) end))
	registerDoor(instance)
	refresh()
	updateCounts()
end

local function toggleLockdown(): ()
	lockdown = not lockdown
	Workspace:SetAttribute("AccessProtocolLockdown", lockdown)
	for _, door in doors do
		if door.level > 0 then
			if lockdown then
				-- A lockdown interrupts opening, closes the panel, then enters Locked.
				moveDoor(door, false)
			elseif door.state == "Locked" then
				setState(door, "Closed")
			end
		end
	end
	for player in sessions do
		showClearance(player)
	end
end

local function addPlayer(player: Player): ()
	if sessions[player] then
		return
	end
	local session: Session = {level = 0, nextAction = 0, connections = {}}
	sessions[player] = session
	table.insert(session.connections, player.CharacterAdded:Connect(function(): ()
		-- Clearance is session-only and resets on respawn, avoiding stale authority.
		session.level = 0
		session.nextAction = 0
		showClearance(player)
	end))
	showClearance(player)
end

local function removePlayer(player: Player): ()
	local session = sessions[player]
	if session then
		disconnectAll(session.connections)
		sessions[player] = nil
	end
	for _, door in doors do
		door.cooldown[player] = nil
	end
end

-- Teardown is installed before startup waits, so even an incomplete lab can release observers.
table.insert(connections, script.Destroying:Connect(function(): ()
	running = false
	for instance in watched do unwatchDoor(instance) end
	for player in sessions do removePlayer(player) end
	disconnectAll(connections)
end))
Workspace:SetAttribute("AccessProtocolLockdown", false)
table.insert(connections, Players.PlayerAdded:Connect(addPlayer))
table.insert(connections, Players.PlayerRemoving:Connect(removePlayer))
for _, player in Players:GetPlayers() do
	addPlayer(player)
end
table.insert(connections, CollectionService:GetInstanceAddedSignal(TAG):Connect(watchDoor))
table.insert(connections, CollectionService:GetInstanceRemovedSignal(TAG):Connect(unwatchDoor))
for _, instance in CollectionService:GetTagged(TAG) do
	watchDoor(instance)
end

local lab = Workspace:WaitForChild("AccessProtocolLab", 10)
local ready = if lab then lab:WaitForChild("Ready", 10) else nil
local terminals = if lab then lab:FindFirstChild("Terminals") else nil
if not ready or not terminals then
	warn("Access Protocol: demo lab unavailable; registered doors remain active")
	return
end
for _, terminal in terminals:GetChildren() do
	if not terminal:IsA("BasePart") then
		continue
	end
	local prompt = terminal:FindFirstChildWhichIsA("ProximityPrompt")
	if not prompt then
		continue
	end
	table.insert(connections, prompt.Triggered:Connect(function(player: Player): ()
		local session = sessions[player]
		if not session or not prompt.Enabled or prompt.Parent ~= terminal
			or not nearAlivePlayer(player, terminal, prompt.MaxActivationDistance + 1)
			or os.clock() < session.nextAction then
			return
		end
		session.nextAction = os.clock() + 0.8
		-- Explicit demo privilege: any nearby live player can cycle levels / lockdown.
		-- Production integrations must replace this with their own server policy.
		if terminal.Name == "ClearanceTerminal" then
			session.level = (session.level + 1) % 3
			showClearance(player)
		elseif terminal.Name == "LockdownTerminal" then
			toggleLockdown()
			terminal.Color = if lockdown then RED else GREEN
			local text = label(terminal)
			if text then
				text.Text = if lockdown then "LOCKDOWN ACTIVE\n[E] RESTORE" else "NORMAL OPERATION\n[E] LOCKDOWN"
			end
		end
	end))
end

script:SetAttribute("Ready", true)