# Projectile System

A high-performance projectile simulation system for Roblox written in **Luau (strict mode)**.

## Features

- Fixed timestep simulation (prevents tunneling)
- Material-based ricochet
- Material penetration system
- Object pooling for performance
- Signal events for projectile lifecycle
- Promise-based async API
- Optional debug visualization

## Usage

```lua
local manager = require(path.to.ProjectileManager)

manager:FireProjectileAsync(origin, direction, 900, {
	Lifetime = 6,
	MaxBounces = 3,
	MaxPenetration = 0.5,
})
```

## Dependencies

This system depends on the following libraries:

- [Promise](https://eryn.io/roblox-lua-promise/)
- [Signal](https://github.com/Sleitnick/RbxUtil/blob/main/modules/signal/init.luau)
