In Quake and derivative engines (like Half-Life 1 & 2), it is possible to slide up sloped surfaces without losing much speed. This is a major gameplay component of games like QuakeWorld Team Fortress, Team Fortress Classic, and Fortress Forever, where maintaining momentum from large speed bursts is fundamental.

![](https://picsum.photos/500/300)

The obvious assumption would be that this is an intentional feature that uses things like the slope of the surface and the player's velocity to determine when a player is rampsliding, but that is not the case. In fact, in the same way that bunnyhopping was likely an unintentional quirk of the 'air acceleration' code, rampsliding was likely an unintentional quirk of the 'categorize position' code.

In [Quake's `PM_CatagorizePosition` \[sic\] function, we see the following code](https://github.com/id-Software/Quake/blob/bf4ac424ce754894ac8f1dae6a3981954bc9852d/QW/client/pmove.c#L587-L590):

```c
if (pmove.velocity[2] > 180)
{
	onground = -1;
}
```

That is, if the player is moving up (velocity index 2 is the vertical component) at greater than 180 units, then the player is automatically considered in the air, and this overrides all other 'on ground' checks. With this, if a player is colliding with a ramp such that their velocity along the ramp has a large enough vertical component, then they are considered in the air and friction is simply not applied (specifically, `PM_AirMove` is called instead of `PM_GroundMove`).

![](https://picsum.photos/500/300)

Similar code exists [in the Half-Life (GoldSrc) engine](https://github.com/ValveSoftware/halflife/blob/c76dd531a79a176eef7cdbca5a80811123afbbe2/pm_shared/pm_shared.c#L1563-L1566):

```c
if (pmove->velocity[2] > 180)   // Shooting up really fast.  Definitely not on ground.
{
	pmove->onground = -1;
}
```

and [in the Half-Life 2 (Source) engine](https://github.com/ValveSoftware/source-sdk-2013/blob/0d8dceea4310fde5706b3ce1c70609d72a38efdf/mp/src/game/shared/gamemovement.cpp#L3832-L3837):

```c++
// Was on ground, but now suddenly am not
if ( bMovingUpRapidly || 
	( bMovingUp && player->GetMoveType() == MOVETYPE_LADDER ) )   
{
	SetGroundEntity( NULL );
}
```

## Why would this code exist?

It seems like this code is mostly a catch-all fix to resolve any instance where a player is moved by an external force that *should* push them off the ground, but that doesn't directly alter the player's "on ground" flag--things like explosions, or `trigger_push` brush entities. This is necessary because the 'on ground' and 'in air' states are handled very differently: for example, when on the ground, the player's vertical velocity is set to zero every frame.
