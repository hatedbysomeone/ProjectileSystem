# Projectile System

A high-performance projectile simulation system for Roblox built with Luau strict typing.

## Features

- Fixed timestep simulation (prevents tunneling)
- Material-based ricochet
- Material penetration system
- Object pooling for performance
- Signal events for projectile lifecycle
- Promise API for async projectile handling
- Debug visualization for impacts and ricochets

## Usage

```lua
local manager = require(path.to.ProjectileManager)

manager:FireProjectileAsync(origin, direction, 900, {
	Lifetime = 6,
	MaxBounces = 3,
	MaxPenetration = 0.5,
})
```
