--!strict

--[[
	Projectile Simulation System

	This module implements a reusable projectile simulation for fast-moving objects.

	Main goals of the system:
	- Avoid tunneling issues for high-speed projectiles
	- Keep projectile simulation stable across different frame rates
	- Reuse projectile objects through pooling to reduce allocations
	- Support per-material ricochet and penetration rules
	- Expose events through Signal
	- Expose lifecycle completion through Promise

	Architecture overview:

	Projectile
		Stores mutable projectile state and visual state

	ProjectilePool
		Reuses projectile objects so the system does not constantly allocate

	ProjectileManager
		Owns simulation, stepping, collision handling, and public API

	Important note:
	This is a client-side ballistic simulation example focused on architecture,
	readability, and extensibility.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)
local Signal = require(ReplicatedStorage.Packages.Signal)

local LOCAL_PLAYER = Players.LocalPlayer or Players.PlayerAdded:Wait()

local DEBUG_ENABLED = true

--[[
	These values represent how easy it is for a projectile to penetrate a material.

	Higher number:
		Easier to pass through

	Lower number:
		Harder to pass through

	ForceField is intentionally 0 so it behaves as non-penetrable.
]]
local MATERIAL_PENETRATION: {[Enum.Material]: number} = {
	[Enum.Material.Glass] = 0.6,
	[Enum.Material.Wood] = 0.4,
	[Enum.Material.Plastic] = 0.3,
	[Enum.Material.Metal] = 0.1,
	[Enum.Material.Concrete] = 0.05,
	[Enum.Material.DiamondPlate] = 0.02,
	[Enum.Material.ForceField] = 0.0,
	[Enum.Material.Ice] = 0.35,
}

--[[
	These values represent how much energy remains after a ricochet.

	Higher number:
		More energy preserved after bouncing

	Lower number:
		Projectile loses more speed on bounce
]]
local MATERIAL_BOUNCE: {[Enum.Material]: number} = {
	[Enum.Material.Glass] = 0.2,
	[Enum.Material.Wood] = 0.35,
	[Enum.Material.Plastic] = 0.45,
	[Enum.Material.Metal] = 0.7,
	[Enum.Material.Concrete] = 0.25,
	[Enum.Material.DiamondPlate] = 0.8,
	[Enum.Material.Ice] = 0.6,
}

export type ProjectileSettings = {
	Gravity: Vector3?,
	Lifetime: number?,
	MaxBounces: number?,
	MaxPenetration: number?,
	Drag: number?,
	VisualLength: number?,
	VisualThickness: number?,
	VisualTransparency: number?,
}

export type HitPayload = {
	ProjectileId: number,
	Position: Vector3,
	Normal: Vector3,
	Material: Enum.Material,
	Instance: Instance?,
}

export type Projectile = {
	Id: number,
	Position: Vector3,
	Velocity: Vector3,
	Gravity: Vector3,
	Speed: number,
	Lifetime: number,
	Age: number,
	BounceCount: number,
	MaxBounces: number,
	MaxPenetration: number,
	PenetrationUsed: number,
	Drag: number,
	Alive: boolean,
	Part: Part?,
	RaycastParams: RaycastParams?,
	LastCFrame: CFrame,
	ResolveCompletion: ((HitPayload?) -> ())?,
	RejectCompletion: ((string) -> ())?,

	Activate: (
		self: Projectile,
		id: number,
		origin: Vector3,
		direction: Vector3,
		speed: number,
		settings: ProjectileSettings,
		part: Part,
		raycastParams: RaycastParams
	) -> (),
	Deactivate: (self: Projectile) -> (),
	UpdateCFrame: (self: Projectile) -> (),
	ResetState: (self: Projectile) -> (),
}

export type ProjectilePool = {
	Available: {Projectile},
	InUse: {[Projectile]: boolean},

	Acquire: (self: ProjectilePool) -> Projectile,
	Release: (self: ProjectilePool, projectile: Projectile) -> (),
}

export type ProjectileManager = {
	ActiveProjectiles: {Projectile},
	Pool: ProjectilePool,
	RaycastParams: RaycastParams,
	FixedStep: number,
	MaxDelta: number,
	NextProjectileId: number,

	ProjectileCreated: any,
	ProjectileUpdated: any,
	ProjectileHit: any,
	ProjectileBounced: any,
	ProjectilePenetrated: any,
	ProjectileDestroyed: any,

	SetIgnoreList: (self: ProjectileManager, ignoreList: {Instance}) -> (),
	CreateVisualPart: (self: ProjectileManager, settings: ProjectileSettings) -> Part,
	CreateProjectile: (self: ProjectileManager, origin: Vector3, direction: Vector3, speed: number, settings: ProjectileSettings) -> Projectile,
	FireProjectileAsync: (self: ProjectileManager, origin: Vector3, direction: Vector3, speed: number, settings: ProjectileSettings) -> any,
	UpdateProjectiles: (self: ProjectileManager, deltaTime: number) -> (),
	UpdateProjectilesForStep: (self: ProjectileManager, stepDelta: number) -> (),
	SimulateProjectile: (self: ProjectileManager, projectile: Projectile, deltaTime: number) -> (),
	HandleCollision: (self: ProjectileManager, projectile: Projectile, raycastResult: RaycastResult, deltaTime: number) -> (),
	TryPenetration: (self: ProjectileManager, projectile: Projectile, material: Enum.Material, impactAngle: number) -> boolean,
	CanBounce: (self: ProjectileManager, projectile: Projectile) -> boolean,
	ApplyBounce: (self: ProjectileManager, projectile: Projectile, hitPosition: Vector3, hitNormal: Vector3, hitMaterial: Enum.Material) -> (),
	StopProjectile: (self: ProjectileManager, projectile: Projectile, hitPayload: HitPayload?) -> (),
	Destroy: (self: ProjectileManager) -> (),
}

--[[
	Returns the current camera.

	The camera may briefly be unavailable very early in startup,
	so a fallback lookup is used.
	@return Camera
]]
local function getCamera(): Camera
	local currentCamera = Workspace.CurrentCamera
	if currentCamera then
		return currentCamera
	end

	local fallbackCamera = Workspace:FindFirstChildWhichIsA("Camera")
	return fallbackCamera :: Camera
end

--[[
	Prints a debug message when debugging is enabled.
	@param label string
	@param detail string?
	@return nil
]]
local function debugLog(label: string, detail: string?): ()
	if not DEBUG_ENABLED then
		return
	end

	if detail then
		print(`[projectile]: {label} - {detail}`)
		return
	end

	print(`[projectile]: {label}`)
end

--[[
	Creates a temporary neon marker in the world.

	This is useful when visually debugging:
	- impacts
	- ricochets
	- penetration events
	@param position Vector3
	@param color Color3
	@param size number?
	@param lifetime number?
	@return nil
]]
local function createDebugMarker(position: Vector3, color: Color3, size: number?, lifetime: number?): ()
	if not DEBUG_ENABLED then
		return
	end

	local marker = Instance.new("Part")
	marker.Size = Vector3.one * (size or 0.45)
	marker.Material = Enum.Material.Neon
	marker.Color = color
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanTouch = false
	marker.CanQuery = false
	marker.CastShadow = false
	marker.CFrame = CFrame.new(position)
	marker.Parent = Workspace

	Debris:AddItem(marker, lifetime or 1)
end

--[[
	Returns a safe unit vector.

	This avoids NaN problems when trying to normalize a zero vector.
	Instead of returning invalid math, a fallback direction is returned.
	@param vector Vector3
	@return Vector3
]]
local function safeUnit(vector: Vector3): Vector3
	if vector.Magnitude <= 0 then
		return -Vector3.zAxis
	end

	return vector.Unit
end

--[[
	Reflects a velocity vector using a surface normal.

	Mathematically:
		reflected = velocity - 2 * (velocity - normal) * normal

	This is the standard reflection formula used for ricochet calculation.
	@param velocity Vector3
	@param normal Vector3
	@return Vector3
]]
local function reflect(velocity: Vector3, normal: Vector3): Vector3
	return velocity - (2 * velocity:Dot(normal)) * normal
end

--[[
	Returns the current mouse position in screen space.
	@return Vector2
]]
local function getMousePosition(): Vector2
	return UserInputService:GetMouseLocation()
end

local Projectile = {} :: any
Projectile.__index = Projectile

--[[
	Constructs a new Projectile object.

	A Projectile only stores state.
	The manager is responsible for simulation and orchestration.
	@return Projectile
]]
function Projectile.new(): Projectile
	local self = setmetatable({}, Projectile) :: Projectile

	self.Id = 0
	self.Position = Vector3.zero
	self.Velocity = Vector3.zero
	self.Gravity = Vector3.new(0, -Workspace.Gravity, 0)
	self.Speed = 1000
	self.Lifetime = 5
	self.Age = 0
	self.BounceCount = 0
	self.MaxBounces = 2
	self.MaxPenetration = 0.3
	self.PenetrationUsed = 0
	self.Drag = 0.05
	self.Alive = false
	self.Part = nil
	self.RaycastParams = nil
	self.LastCFrame = CFrame.new()
	self.ResolveCompletion = nil
	self.RejectCompletion = nil

	return self
end

--[[
	Resets projectile state before returning it to the pool.

	This makes pooled reuse safer because old state is not allowed
	to leak into the next activation.
	@return nil
]]
function Projectile:ResetState(): ()
	self.Id = 0
	self.Position = Vector3.zero
	self.Velocity = Vector3.zero
	self.Gravity = Vector3.new(0, -Workspace.Gravity, 0)
	self.Speed = 1000
	self.Lifetime = 5
	self.Age = 0
	self.BounceCount = 0
	self.MaxBounces = 2
	self.MaxPenetration = 0.3
	self.PenetrationUsed = 0
	self.Drag = 0.05
	self.Alive = false
	self.RaycastParams = nil
	self.LastCFrame = CFrame.new()
	self.ResolveCompletion = nil
	self.RejectCompletion = nil

	local part = self.Part
	if part then
		part.Parent = nil
	end
end

--[[
	Activates a projectile for live simulation.

	Why this exists:
	Because pooled projectiles are reused, we need a method that fully
	re-initializes all state when a projectile is fired again.
	@param id number
	@param origin Vector3
	@param direction Vector3
	@param speed number
	@param settings ProjectileSettings
	@param part Part
	@param raycastParams RaycastParams
	@return nil
]]
function Projectile:Activate(
	id: number,
	origin: Vector3,
	direction: Vector3,
	speed: number,
	settings: ProjectileSettings,
	part: Part,
	raycastParams: RaycastParams
): ()
	self.Id = id
	self.Position = origin
	self.Speed = speed
	self.Velocity = safeUnit(direction) * speed
	self.Gravity = settings.Gravity or Vector3.new(0, -Workspace.Gravity, 0)
	self.Lifetime = settings.Lifetime or 5
	self.MaxBounces = settings.MaxBounces or 2
	self.MaxPenetration = settings.MaxPenetration or 0.3
	self.Drag = settings.Drag or 0.05
	self.Age = 0
	self.BounceCount = 0
	self.PenetrationUsed = 0
	self.Alive = true
	self.Part = part
	self.RaycastParams = raycastParams
	self.LastCFrame = CFrame.new(origin, origin + safeUnit(self.Velocity))

	part.CFrame = self.LastCFrame
	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero
	part.Parent = Workspace
end

--[[
	Deactivates the projectile.

	The projectile object itself is not destroyed here.
	It is simply marked inactive and its visual part is detached,
	so the pool may later recycle it.
	@return nil
]]
function Projectile:Deactivate(): ()
	self.Alive = false

	local part = self.Part
	if not part then
		return
	end

	part.Parent = nil
end

--[[
	Updates the projectile's visual orientation.

	The projectile tracer always faces along its current velocity direction,
	which makes the visual look aligned with the flight path.
	@return nil
]]
function Projectile:UpdateCFrame(): ()
	local part = self.Part
	if not part then
		return
	end

	local direction = safeUnit(self.Velocity)
	self.LastCFrame = CFrame.new(self.Position, self.Position + direction)
	part.CFrame = self.LastCFrame
end

local ProjectilePool = {} :: any
ProjectilePool.__index = ProjectilePool

--[[
	Constructs a new ProjectilePool object.

	Object pooling is used to reduce allocations.
	This matters when firing many projectiles in a short period of time.
	@return ProjectilePool
]]
function ProjectilePool.new(): ProjectilePool
	local self = setmetatable({}, ProjectilePool) :: ProjectilePool
	self.Available = {}
	self.InUse = {}
	return self
end

--[[
	Returns a projectile from the pool.

	If one is available, it is reused.
	If none are available, a new one is created.
	@return Projectile
]]
function ProjectilePool:Acquire(): Projectile
	local projectile = table.remove(self.Available)
	if projectile ~= nil then
		local pooledProjectile = projectile :: Projectile
		self.InUse[pooledProjectile] = true
		return pooledProjectile
	end

	local newProjectile = Projectile.new()
	self.InUse[newProjectile] = true
	return newProjectile
end

--[[
	Returns a projectile back to the pool.

	The projectile is reset before becoming available again.
	@param projectile Projectile
	@return nil
]]
function ProjectilePool:Release(projectile: Projectile): ()
	self.InUse[projectile] = nil
	projectile:ResetState()
	table.insert(self.Available, projectile)
end

local ProjectileManager = {} :: any
ProjectileManager.__index = ProjectileManager

--[[
	Constructs a new ProjectileManager object.

	The manager owns:
	- active projectile tracking
	- collision stepping
	- signal dispatching
	- public firing API
	@return ProjectileManager
]]
function ProjectileManager.new(): ProjectileManager
	local self = setmetatable({}, ProjectileManager) :: ProjectileManager

	self.ActiveProjectiles = {}
	self.Pool = ProjectilePool.new()

	self.RaycastParams = RaycastParams.new()
	self.RaycastParams.FilterType = Enum.RaycastFilterType.Exclude
	self.RaycastParams.IgnoreWater = true
	self.RaycastParams.FilterDescendantsInstances = {}

	--[[
		FixedStep is intentionally smaller than a typical frame delta.

		Why:
		Fast projectiles can travel a large distance in one frame.
		If simulation only ran once per frame, a projectile could skip through thin geometry.

		By slicing time into smaller chunks, we greatly reduce tunneling risk.
	]]
	self.FixedStep = 1 / 120

	--[[
		MaxDelta clamps unusually large frame times.

		This prevents a huge simulation catch-up after frame drops,
		which could otherwise create unstable or expensive update spikes.
	]]
	self.MaxDelta = 1 / 30

	self.NextProjectileId = 0

	self.ProjectileCreated = Signal.new()
	self.ProjectileUpdated = Signal.new()
	self.ProjectileHit = Signal.new()
	self.ProjectileBounced = Signal.new()
	self.ProjectilePenetrated = Signal.new()
	self.ProjectileDestroyed = Signal.new()

	return self
end

--[[
	Replaces the ignore list used for projectile raycasts.

	Usually this includes the local character so the projectile
	does not instantly hit the shooter.
	@param ignoreList {Instance}
	@return nil
]]
function ProjectileManager:SetIgnoreList(ignoreList: {Instance}): ()
	self.RaycastParams.FilterDescendantsInstances = ignoreList
end

--[[
	Creates the visual tracer part.

	This part is cosmetic only.
	Actual collision detection is done with raycasts, not physics collision.
	@param settings ProjectileSettings
	@return Part
]]
function ProjectileManager:CreateVisualPart(settings: ProjectileSettings): Part
	local visualLength = settings.VisualLength or 2.5
	local visualThickness = settings.VisualThickness or 0.35
	local visualTransparency = settings.VisualTransparency or 0.1

	local part = Instance.new("Part")
	part.Size = Vector3.new(visualThickness, visualThickness, visualLength)
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(255, 70, 70)
	part.Transparency = visualTransparency
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Anchored = true
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	return part
end

--[[
	Creates and registers a projectile.

	This is the synchronous low-level creation path.
	Signals are fired immediately after registration.
	@param origin Vector3
	@param direction Vector3
	@param speed number
	@param settings ProjectileSettings
	@return Projectile
]]
function ProjectileManager.CreateProjectile(
	self: ProjectileManager,
	origin: Vector3,
	direction: Vector3,
	speed: number,
	settings: ProjectileSettings
): Projectile
	self.NextProjectileId += 1

	local projectile = self.Pool:Acquire()
	local visualPart = self:CreateVisualPart(settings)

	projectile:Activate(
		self.NextProjectileId,
		origin,
		direction,
		speed,
		settings,
		visualPart,
		self.RaycastParams
	)

	table.insert(self.ActiveProjectiles, projectile)

	self.ProjectileCreated:Fire(projectile)
	debugLog("createProjectile", tostring(projectile.Id))

	return projectile
end

--[[
	Fires a projectile and returns a Promise.

	The Promise resolves when the projectile finishes its life:
	- on hit
	- on stop
	- on expiration

	This is useful for integrating with:
	- effects systems
	- damage systems
	- UI feedback
	- asynchronous orchestration
	@param origin Vector3
	@param direction Vector3
	@param speed number
	@param settings ProjectileSettings
	@return Promise
]]
function ProjectileManager:FireProjectileAsync(
	origin: Vector3,
	direction: Vector3,
	speed: number,
	settings: ProjectileSettings
): any
	local manager = self

	--[[
		Luau currently struggles to correctly infer the generic type packs used by Promise.new.
		Even when the executor function is valid, the typechecker may produce errors such as
		"Expected '(A...) -> (R1...)'".

		To avoid incorrect type errors while keeping the runtime behavior unchanged,
		we cast Promise.new to 'any'. This bypasses the type inference issue while
		still allowing the Promise implementation to work normally at runtime.

		:(
	]]
	local promiseNew = Promise.new :: any

	return promiseNew(function(resolve, reject)
		local projectile = manager:CreateProjectile(origin, direction, speed, settings)
		projectile.ResolveCompletion = resolve
		projectile.RejectCompletion = reject
	end)
end

--[[
	Returns whether a projectile may still bounce.
	@param projectile Projectile
	@return boolean
]]
function ProjectileManager:CanBounce(projectile: Projectile): boolean
	return projectile.BounceCount < projectile.MaxBounces
end

--[[
	Applies bounce logic after impact.

	Process:
	1. Compute reflected velocity
	2. Apply material bounce coefficient
	3. Move the projectile slightly away from the surface

	The small surface offset prevents the next raycast from starting
	inside the impacted surface.
	@param projectile Projectile
	@param hitPosition Vector3
	@param hitNormal Vector3
	@param hitMaterial Enum.Material
	@return nil
]]
function ProjectileManager:ApplyBounce(
	projectile: Projectile,
	hitPosition: Vector3,
	hitNormal: Vector3,
	hitMaterial: Enum.Material
): ()
	projectile.BounceCount += 1

	local bounceFactor = MATERIAL_BOUNCE[hitMaterial] or 0.4
	local reflectedVelocity = reflect(projectile.Velocity, hitNormal)

	projectile.Velocity = reflectedVelocity * bounceFactor
	projectile.Position = hitPosition + hitNormal * 0.02
	projectile:UpdateCFrame()

	self.ProjectileBounced:Fire(projectile, hitPosition, hitNormal, hitMaterial)

	createDebugMarker(hitPosition, Color3.fromRGB(255, 200, 0), 0.5, 1)
	debugLog("bounce", hitMaterial.Name)
end

--[[
	Attempts to apply penetration to a projectile.

	Penetration considers:
	- material penetrability
	- impact angle
	- remaining projectile penetration budget

	Shallower impacts are more likely to penetrate.
	If the required penetration exceeds the available budget,
	penetration fails.

	The formula is simplified, but expressive enough for gameplay systems.
	@param projectile Projectile
	@param material Enum.Material
	@param impactAngle number
	@return boolean
]]
function ProjectileManager:TryPenetration(
	projectile: Projectile,
	material: Enum.Material,
	impactAngle: number
): boolean
	local materialAllowance = MATERIAL_PENETRATION[material]
	if not materialAllowance then
		return false
	end

	if materialAllowance <= 0 then
		return false
	end

	local angleFactor = math.clamp(1 - (impactAngle / 90), 0, 1)

	--[[
		Estimated thickness is derived from the inverse of the material allowance.

		More penetrable material:
			Lower resistance

		Less penetrable material:
			Higher resistance
	]]
	local estimatedThickness = (1 - materialAllowance) * 0.5

	--[[
		At low angleFactor, penetration becomes more expensive.
		A floor is used to avoid division by zero and absurd values.
	]]
	local requiredPenetration = estimatedThickness * (1 / math.max(angleFactor, 0.1))
	local nextPenetrationValue = projectile.PenetrationUsed + requiredPenetration

	if nextPenetrationValue > projectile.MaxPenetration then
		debugLog("no-penetrate", material.Name)
		return false
	end

	projectile.PenetrationUsed = nextPenetrationValue

	--[[
		Penetration costs energy.
		The projectile loses part of its velocity after passing through.
	]]
	projectile.Velocity *= (1 - materialAllowance * 0.5)

	self.ProjectilePenetrated:Fire(projectile, material, impactAngle)

	debugLog("penetrate", material.Name)
	return true
end

--[[
	Stops a projectile and resolves its lifecycle Promise if present.

	The projectile is marked inactive immediately.
	The manager removes and pools it on the next maintenance pass.
	@param projectile Projectile
	@param hitPayload HitPayload?
	@return nil
]]
function ProjectileManager:StopProjectile(projectile: Projectile, hitPayload: HitPayload?): ()
	if not projectile.Alive then
		return
	end

	projectile:Deactivate()
	self.ProjectileDestroyed:Fire(projectile, hitPayload)

	local resolveCompletion = projectile.ResolveCompletion
	if not resolveCompletion then
		return
	end

	projectile.ResolveCompletion = nil
	projectile.RejectCompletion = nil
	resolveCompletion(hitPayload)
end

--[[
	Handles a raycast collision.

	Decision order:
	1. Try penetration
	2. If penetration fails, try bounce
	3. If bounce is no longer allowed, stop projectile

	Using this order makes shallow, penetrable impacts continue,
	while hard impacts ricochet or terminate.
	@param projectile Projectile
	@param raycastResult RaycastResult
	@param deltaTime number
	@return nil
]]
function ProjectileManager:HandleCollision(
	projectile: Projectile,
	raycastResult: RaycastResult,
	deltaTime: number
): ()
	local hitPosition = raycastResult.Position
	local hitNormal = raycastResult.Normal
	local hitMaterial = raycastResult.Material
	local hitInstance = raycastResult.Instance

	projectile.Position = hitPosition

	local incomingDirection = safeUnit(projectile.Velocity)
	local impactDot = math.clamp(incomingDirection:Dot(-hitNormal), -1, 1)
	local impactAngle = math.deg(math.acos(impactDot))

	local hitPayload: HitPayload = {
		ProjectileId = projectile.Id,
		Position = hitPosition,
		Normal = hitNormal,
		Material = hitMaterial,
		Instance = hitInstance,
	}

	self.ProjectileHit:Fire(projectile, hitPayload)

	local penetrated = self:TryPenetration(projectile, hitMaterial, impactAngle)
	if penetrated then
		createDebugMarker(hitPosition, Color3.fromRGB(0, 255, 120), 0.5, 1)

		--[[
			After penetrating, the projectile is nudged slightly forward.
			This prevents the next raycast from immediately colliding with the same surface again.
		]]
		projectile.Position = hitPosition + incomingDirection * 0.1
		projectile:UpdateCFrame()

		local remainingDelta = deltaTime * 0.25
		if remainingDelta <= 0 then
			return
		end

		self:SimulateProjectile(projectile, remainingDelta)
		return
	end

	if not self:CanBounce(projectile) then
		self:StopProjectile(projectile, hitPayload)
		return
	end

	self:ApplyBounce(projectile, hitPosition, hitNormal, hitMaterial)
end

--[[
	Simulates one projectile for a single step.

	This uses:
	- gravity
	- drag
	- raycast-based collision

	Raycasting is used instead of relying on physical collisions because
	high-speed projectiles can move too far per frame and tunnel through parts.
	@param projectile Projectile
	@param deltaTime number
	@return nil
]]
function ProjectileManager:SimulateProjectile(projectile: Projectile, deltaTime: number): ()
	if not projectile.Alive then
		return
	end

	projectile.Age += deltaTime

	if projectile.Age >= projectile.Lifetime then
		self:StopProjectile(projectile, nil)
		return
	end

	local currentVelocity = projectile.Velocity

	--[[
		Gravity is integrated first, then drag is applied.

		Drag simulates air resistance and gradually reduces speed over time.
		This prevents unrealistic endless travel.
	]]
	local newVelocity = currentVelocity + projectile.Gravity * deltaTime
	newVelocity *= (1 - projectile.Drag * deltaTime)

	--[[
		We use the average of old and new velocity for displacement.
		This is a simple semi-implicit style approximation that behaves
		better than using only one endpoint velocity.
	]]
	local displacement = (currentVelocity + newVelocity) * 0.5 * deltaTime
	local origin = projectile.Position
	local target = origin + displacement

	local raycastResult = Workspace:Raycast(origin, target - origin, projectile.RaycastParams)
	if raycastResult then
		self:HandleCollision(projectile, raycastResult, deltaTime)
		return
	end

	projectile.Position = target
	projectile.Velocity = newVelocity
	projectile:UpdateCFrame()

	self.ProjectileUpdated:Fire(projectile)
end

--[[
	Updates all active projectiles for a single fixed simulation step.

	This function is intentionally separate from UpdateProjectiles
	so the outer loop stays simple and readable.
	@param stepDelta number
	@return nil
]]
function ProjectileManager:UpdateProjectilesForStep(stepDelta: number): ()
	local index = 1

	while index <= #self.ActiveProjectiles do
		local projectile = self.ActiveProjectiles[index] :: Projectile

		if not projectile.Alive then
			table.remove(self.ActiveProjectiles, index)
			self.Pool:Release(projectile)
			continue
		end

		self:SimulateProjectile(projectile, stepDelta)

		if projectile.Alive then
			index += 1
			continue
		end

		table.remove(self.ActiveProjectiles, index)
		self.Pool:Release(projectile)
	end
end

--[[
	Updates all projectiles using fixed-step simulation.

	Why fixed-step:
	If we simulated using only raw frame delta, projectile behavior could vary
	based on frame rate, and fast projectiles would be more likely to tunnel.

	Why clamp large frame delta:
	Very large frame times can create unstable catch-up behavior.
	@param deltaTime number
	@return nil
]]
function ProjectileManager:UpdateProjectiles(deltaTime: number)
	local cappedDelta = math.min(deltaTime, self.MaxDelta)
	local remainingDelta = cappedDelta

	while remainingDelta > 0 do
		local stepDelta = math.min(remainingDelta, self.FixedStep)
		self:UpdateProjectilesForStep(stepDelta)
		remainingDelta -= stepDelta
	end
end

--[[
	Destroys the manager and all owned signals.

	This should be called when the system is no longer needed.
	@return nil
]]
function ProjectileManager:Destroy(): ()
	self.ProjectileCreated:Destroy()
	self.ProjectileUpdated:Destroy()
	self.ProjectileHit:Destroy()
	self.ProjectileBounced:Destroy()
	self.ProjectilePenetrated:Destroy()
	self.ProjectileDestroyed:Destroy()

	for _, projectile in self.ActiveProjectiles do
		projectile:Deactivate()
	end

	table.clear(self.ActiveProjectiles)
end

local projectileManager = ProjectileManager.new()
local lastClickTime = 0

--[[
	Returns a reasonable projectile spawn origin.

	Priority:
	1. Character head
	2. Character primary part
	3. Camera position

	This makes the projectile spawn feel visually connected to the player.
	@return Vector3
]]
local function getMuzzleOrigin(): Vector3
	local camera = getCamera()
	local character = LOCAL_PLAYER.Character

	if not character then
		return camera.CFrame.Position
	end

	local head = character:FindFirstChild("Head") :: BasePart?
	if head then
		return head.Position + head.CFrame.LookVector * 1.5
	end

	local rootPart = character.PrimaryPart
	if rootPart then
		return rootPart.Position
	end

	return camera.CFrame.Position
end

--[[
	Returns the shoot direction based on camera and cursor position.

	A viewport ray is cast from the mouse position,
	and its direction is used as the projectile firing direction.
	@return Vector3
]]
local function getShootDirection(): Vector3
	local camera = getCamera()
	local mousePosition = getMousePosition()
	local screenRay = camera:ViewportPointToRay(mousePosition.X, mousePosition.Y)
	return safeUnit(screenRay.Direction)
end

--[[
	Builds the raycast ignore list.

	The local character is ignored so the projectile does not immediately hit
	the player who fired it.
	@return nil
]]
local function buildIgnoreList(): ()
	local ignoreList: {Instance} = {}

	local character = LOCAL_PLAYER.Character
	if character then
		table.insert(ignoreList, character)
	end

	projectileManager:SetIgnoreList(ignoreList)
end

--[[
	Fires a projectile using the current local view.

	This helper shows how the manager API can be consumed by gameplay code.
	@return nil
]]
local function fireProjectile(): ()
	buildIgnoreList()

	local origin = getMuzzleOrigin()
	local direction = getShootDirection()

	local settings: ProjectileSettings = {
		Gravity = Vector3.new(0, -Workspace.Gravity, 0),
		Lifetime = 6,
		MaxBounces = 3,
		MaxPenetration = 0.5,
		Drag = 0.05,
		VisualLength = 2.5,
		VisualThickness = 0.35,
		VisualTransparency = 0.1,
	}

	projectileManager:FireProjectileAsync(origin, direction, 900, settings)
		:andThen(function(hitPayload: HitPayload?)
			if not hitPayload then
				debugLog("resolved", "expired without hit payload")
				return
			end

			debugLog("resolved", `hit {hitPayload.Material.Name}`)
		end)
		:catch(function(errorMessage: string)
			warn("[projectile]: promise rejected", errorMessage)
		end)
end

--[[
	Handles input for firing.

	Early returns are used to reduce nesting and keep the function readable.
	@param inputObject InputObject
	@param gameProcessed boolean
	@return nil
]]
local function onInputBegan(inputObject: InputObject, gameProcessed: boolean): ()
	if gameProcessed then
		return
	end

	if inputObject.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return
	end

	local currentTime = Workspace:GetServerTimeNow()
	if currentTime - lastClickTime < 0.05 then
		return
	end

	lastClickTime = currentTime
	fireProjectile()
end

--[[
	Updates projectile simulation every frame.
	@param deltaTime number
	@return nil
]]
local function onHeartbeat(deltaTime: number): ()
	projectileManager:UpdateProjectiles(deltaTime)
end

--[[
	Optional signal listeners.

	These are examples of how external systems could subscribe to projectile events.
	In a production game, damage, sound, particles, or analytics could hook here.
]]
projectileManager.ProjectileHit:Connect(function(projectile: Projectile, hitPayload: HitPayload)
	debugLog("signal-hit", `id={projectile.Id}, material={hitPayload.Material.Name}`)
end)

projectileManager.ProjectileBounced:Connect(function(projectile: Projectile, _: Vector3, _: Vector3, hitMaterial: Enum.Material)
	debugLog("signal-bounce", `id={projectile.Id}, material={hitMaterial.Name}`)
end)

projectileManager.ProjectilePenetrated:Connect(function(projectile: Projectile, material: Enum.Material, impactAngle: number)
	debugLog("signal-penetrate", `id={projectile.Id}, material={material.Name}, angle={math.floor(impactAngle)}`)
end)

UserInputService.InputBegan:Connect(onInputBegan)
RunService.Heartbeat:Connect(onHeartbeat)

return projectileManager
