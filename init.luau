--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

-- rough penetration values (higher = easier to penetrate)
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

-- bounce coefficient per material (higher = bouncier)
local MATERIAL_BOUNCE: {[Enum.Material]: number} = {
	[Enum.Material.Glass] = 0.2,
	[Enum.Material.Wood] = 0.35,
	[Enum.Material.Plastic] = 0.45,
	[Enum.Material.Metal] = 0.7,
	[Enum.Material.Concrete] = 0.25,
	[Enum.Material.DiamondPlate] = 0.8,
	[Enum.Material.Ice] = 0.6,
}

local LOCAL_PLAYER: Player = Players.LocalPlayer or Players.PlayerAdded:Wait()

-- camera can be nil very early, so we guard for that
local function getCamera(): Camera
	local cam = Workspace.CurrentCamera
	if not cam then
		cam = Workspace:FindFirstChildWhichIsA("Camera")
	end
	return cam :: Camera
end

local CAMERA: Camera = getCamera()

-- debug stuff (set false to silence prints + markers)
local DEBUG: boolean = true

local function dbg(name: string, extra: string?): ()
	if not DEBUG then return end
	
	if extra then
		print(`[proj]: {name} - {extra}`)
	else
		print(`[proj]: {name}`)
	end
end

-- tiny neon markers to visualize hits/bounces in world
local function debugMarker(pos: Vector3, color: Color3, size: number?, life: number?): ()
	if not DEBUG then return end

	local part = Instance.new("Part")
	part.Size = Vector3.new(1, 1, 1) * (size or 0.45)
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.CFrame = CFrame.new(pos)
	part.Parent = Workspace

	Debris:AddItem(part, life or 1)
end

-- safe unit for zero vectors (prevents NaNs)
local function safeUnit(v: Vector3): Vector3
	if v.Magnitude > 0 then
		return v.Unit
	end
	return -Vector3.zAxis
end

-- reflect velocity from a surface
local function reflect(velocity: Vector3, normal: Vector3): Vector3
	return velocity - (2 * velocity:Dot(normal)) * normal
end

local function getMousePos(): Vector2
	return UserInputService:GetMouseLocation()
end

-- settings used when creating a projectile
export type ProjectileSettings = {
	Gravity: Vector3?,
	Lifetime: number?,
	MaxBounces: number?,
	MaxPenetration: number?,
	Drag: number?,
}

export type Projectile = {
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
	Activate: (self: Projectile, origin: Vector3, direction: Vector3, speed: number?, settings: ProjectileSettings, part: Part, rayParams: RaycastParams) -> (),
	Deactivate: (self: Projectile) -> (),
	UpdateCFrame: (self: Projectile) -> (),
}

export type ProjectilePool = {
	Pool: {Projectile},
	InUse: {[Projectile]: boolean},
	Acquire: (self: ProjectilePool) -> Projectile,
	Release: (self: ProjectilePool, proj: Projectile) -> (),
}

export type ProjectileManager = {
	Active: {Projectile},
	Pool: ProjectilePool,
	RaycastParams: RaycastParams,
	FixedStep: number,
	MaxDelta: number,
	SetIgnoreList: (self: ProjectileManager, list: {Instance}) -> (),
	CreateVisualPart: (self: ProjectileManager) -> Part,
	CreateProjectile: (self: ProjectileManager, origin: Vector3, direction: Vector3, speed: number, settings: ProjectileSettings) -> Projectile,
	UpdateProjectiles: (self: ProjectileManager, dt: number) -> (),
	SimulateProjectile: (self: ProjectileManager, projectile: Projectile, dt: number) -> (),
	HandleCollision: (self: ProjectileManager, projectile: Projectile, raycastResult: RaycastResult, dt: number) -> (),
	CalculateRicochet: (self: ProjectileManager, velocity: Vector3, normal: Vector3) -> Vector3,
	ApplyPenetration: (self: ProjectileManager, projectile: Projectile, material: Enum.Material, angle: number) -> boolean,
}


-- Projectile class via metatable
local Projectile = {} :: any
Projectile.__index = Projectile

function Projectile.new(): Projectile
	local self = setmetatable({}, Projectile) :: Projectile

	self.Position = Vector3.new()
	self.Velocity = Vector3.new()
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

	return self
end

-- fully initialize a pooled projectile for reuse
function Projectile:Activate(origin: Vector3, direction: Vector3, speed: number?, settings: ProjectileSettings, part: Part, rayParams: RaycastParams): ()
	self.Position = origin

	self.Speed = speed or self.Speed
	self.Velocity = safeUnit(direction) * self.Speed

	self.Gravity = settings.Gravity or self.Gravity
	self.Lifetime = settings.Lifetime or self.Lifetime
	self.MaxBounces = settings.MaxBounces or self.MaxBounces
	self.MaxPenetration = settings.MaxPenetration or self.MaxPenetration
	self.Drag = settings.Drag or self.Drag

	self.BounceCount = 0
	self.PenetrationUsed = 0
	self.Age = 0
	self.Alive = true

	self.Part = part
	self.RaycastParams = rayParams
	self.LastCFrame = CFrame.new(origin, origin + safeUnit(self.Velocity))

	local p: Part = part
	p.CFrame = self.LastCFrame
	p.AssemblyLinearVelocity = Vector3.new()
	p.AssemblyAngularVelocity = Vector3.new()
	p.Parent = Workspace
end

-- return projectile to idle state (kept in pool)
function Projectile:Deactivate(): ()
	self.Alive = false
	local p = self.Part
	if p then
		p.Parent = nil
	end
end

-- rotate visual part along flight direction
function Projectile:UpdateCFrame(): ()
	if not self.Part then
		return
	end
	local dir = safeUnit(self.Velocity)
	self.LastCFrame = CFrame.new(self.Position, self.Position + dir)
	self.Part.CFrame = self.LastCFrame
end

-- object pool to reuse projectiles (reduces allocations)
local ProjectilePool = {} :: any
ProjectilePool.__index = ProjectilePool

function ProjectilePool.new(): ProjectilePool
	local self = setmetatable({}, ProjectilePool) :: ProjectilePool
	self.Pool = {}
	self.InUse = {}
	return self
end

function ProjectilePool:Acquire(): Projectile
	local proj = table.remove(self.Pool)
	if not proj then
		proj = Projectile.new()
	end
	self.InUse[proj] = true
	return proj
end

function ProjectilePool:Release(proj: Projectile): ()
	self.InUse[proj] = nil
	table.insert(self.Pool, proj)
end



-- manager that updates all projectiles
local ProjectileManager = {} :: any
ProjectileManager.__index = ProjectileManager

function ProjectileManager.new(): ProjectileManager
	local self = setmetatable({}, ProjectileManager) :: ProjectileManager

	self.Active = {}
	self.Pool = ProjectilePool.new()

	self.RaycastParams = RaycastParams.new()
	self.RaycastParams.FilterType = Enum.RaycastFilterType.Exclude
	self.RaycastParams.IgnoreWater = true
	self.RaycastParams.FilterDescendantsInstances = {}

	-- fixed step keeps collision stable even on variable framerate
	self.FixedStep = 1 / 120
	self.MaxDelta = 1 / 30

	return self
end

function ProjectileManager:CalculateRicochet(velocity: Vector3, normal: Vector3): Vector3
	return reflect(velocity, normal)
end

function ProjectileManager:SetIgnoreList(list: {Instance}): ()
	self.RaycastParams.FilterDescendantsInstances = list
end

-- visual tracer part (purely cosmetic)
function ProjectileManager:CreateVisualPart(): Part
	local part = Instance.new("Part")

	part.Size = Vector3.new(0.35, 0.35, 2.5)
	part.Material = Enum.Material.Neon
	part.BrickColor = BrickColor.new("Really red")
	part.Transparency = 0.1

	part.CanCollide = false
	part.Anchored = true
	part.CastShadow = false

	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	return part
end

function ProjectileManager:CreateProjectile(origin: Vector3, direction: Vector3, speed: number, settings: ProjectileSettings): Projectile
	local proj = self.Pool:Acquire()
	local part = self:CreateVisualPart()
	local rayParams = self.RaycastParams

	proj:Activate(origin, direction, speed, settings, part, rayParams)
	table.insert(self.Active, proj)

	dbg("createProjectile")

	return proj
end

-- advance all active projectiles in fixed time slices
function ProjectileManager:UpdateProjectiles(dt: number): ()
	local capped = math.min(dt, self.MaxDelta)
	local step = self.FixedStep
	local remaining = capped

	while remaining > 0 do
		local slice = math.min(remaining, step)

		local i = 1
		while i <= #self.Active do
			local proj = self.Active[i]

			if proj.Alive then
				self:SimulateProjectile(proj, slice)
				i += 1
			else
				table.remove(self.Active, i)
				self.Pool:Release(proj)
			end
		end

		remaining -= slice
	end
end

-- flight physics + gravity
function ProjectileManager:SimulateProjectile(projectile: Projectile, dt: number): ()
	projectile.Age += dt

	if projectile.Age >= projectile.Lifetime then
		projectile:Deactivate()
		return
	end

	local acceleration = projectile.Gravity
	local newVelocity = projectile.Velocity + acceleration * dt

	newVelocity = newVelocity * (1 - projectile.Drag * dt)

	local displacement = (projectile.Velocity + newVelocity) * 0.5 * dt

	local origin = projectile.Position
	local target = origin + displacement

	local rayResult = Workspace:Raycast(origin, target - origin, projectile.RaycastParams)

	if rayResult then
		self:HandleCollision(projectile, rayResult, dt)
		return
	end

	projectile.Position = target
	projectile.Velocity = newVelocity
	projectile:UpdateCFrame()
end

function ProjectileManager:HandleCollision(projectile: Projectile, raycastResult: RaycastResult, dt: number): ()
	local hitPosition = raycastResult.Position
	local hitNormal = raycastResult.Normal
	local hitMaterial = raycastResult.Material

	projectile.Position = hitPosition

	-- ricochet uses reflection
	local reflectVel: Vector3 = self:CalculateRicochet(projectile.Velocity, hitNormal)
	local angle = math.deg(math.acos(math.clamp(safeUnit(projectile.Velocity):Dot(hitNormal * -1), -1, 1)))

	-- penetration check (lower angles have a better chance)
	local didPenetrate = self:ApplyPenetration(projectile, hitMaterial, angle)

	if didPenetrate then
		debugMarker(hitPosition, Color3.fromRGB(0, 255, 120), 0.5, 1)

		-- give the projectile a tiny nudge forward before continuing
		local remaining = dt * 0.25
		projectile.Position = hitPosition + safeUnit(projectile.Velocity) * 0.1
		projectile:UpdateCFrame()
		projectile.Velocity = projectile.Velocity

		if remaining > 0 then
			self:SimulateProjectile(projectile, remaining)
		end

		return
	end

	if projectile.BounceCount < projectile.MaxBounces then
		projectile.BounceCount += 1

		local bounce = MATERIAL_BOUNCE[hitMaterial] or 0.4
		projectile.Velocity = reflectVel * bounce
		projectile.Position = hitPosition + hitNormal * 0.02
		projectile:UpdateCFrame()

		debugMarker(hitPosition, Color3.fromRGB(255, 200, 0), 0.5, 1)
		dbg("bounce", hitMaterial.Name)
	else
		projectile:Deactivate()
	end
end

-- penetration logic (angle makes it harder)
function ProjectileManager:ApplyPenetration(projectile: Projectile, material: Enum.Material, angle: number): boolean
	local allowance = MATERIAL_PENETRATION[material]
	if not allowance or allowance <= 0 then
		return false
	end

	local angleFactor = math.clamp(1 - (angle / 90), 0, 1)
	local thickness = (1 - allowance) * 0.5
	local required = thickness * (1 / math.max(angleFactor, 0.1))

	if projectile.PenetrationUsed + required > projectile.MaxPenetration then
		dbg("no-penetrate", material.Name)
		return false
	end

	projectile.PenetrationUsed += required
	projectile.Velocity = projectile.Velocity * (1 - allowance * 0.5)

	dbg("penetrate", material.Name)

	return true
end



local manager: ProjectileManager = ProjectileManager.new()

-- origin roughly from head/camera so shots come from the player
local function getMuzzleOrigin(): Vector3
	local character = LOCAL_PLAYER.Character
	local cam = getCamera()

	if not character then
		return cam.CFrame.Position
	end

	local head = character:FindFirstChild("Head") :: BasePart?
	if head then
		return head.Position + head.CFrame.LookVector * 1.5
	end

	local root = character.PrimaryPart
	if root then
		return root.Position
	end

	return cam.CFrame.Position
end

-- direction based on mouse
local function getShootDirection(): Vector3
	local cam = getCamera()
	local mousePos = getMousePos()

	local ray = cam:ViewportPointToRay(mousePos.X, mousePos.Y)

	return safeUnit(ray.Direction)
end

local function buildIgnoreList(): ()
	local list: { Instance } = {LOCAL_PLAYER.Character :: Instance}
	manager:SetIgnoreList(list)
end

-- simple fire helper
local function fireProjectile(): ()
	buildIgnoreList()

	local origin = getMuzzleOrigin()
	local dir = getShootDirection()

	local settings: ProjectileSettings = {
		Gravity = Vector3.new(0, -Workspace.Gravity, 0),
		Lifetime = 6,
		MaxBounces = 3,
		MaxPenetration = 0.5,
		Drag = 0.05,
	}

	manager:CreateProjectile(origin, dir, 900, settings)
end

local lastClick = 0

-- demo: click to shoot
UserInputService.InputBegan:Connect(function(input: InputObject, gp: boolean)
	if gp then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		local now = workspace:GetServerTimeNow()
		if (now - lastClick < 0.05) then return end
		
		lastClick = now
		fireProjectile()
	end
end)

-- main update loop
RunService.Heartbeat:Connect(function(dt: number)
	manager:UpdateProjectiles(dt)
end)
