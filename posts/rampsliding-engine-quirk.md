In Quake and derivative engines (like Half-Life 1 & 2), it is possible to slide up sloped surfaces without losing much speed. This is a major gameplay component of games like QuakeWorld Team Fortress, Team Fortress Classic, and Fortress Forever, where maintaining momentum from large speed bursts is fundamental.

<div style="text-align: center;">
<video autoplay loop muted style="margin-left:auto; margin-right:auto; display: block;">
	<source src="/images/rampsliding-engine-quirk/rampslide.mp4" type="video/mp4">
</video>
<i style="background-color: rgba(0,0,0, .1); margin:0; padding: .25em;">Rampsliding in Team Fortress Classic from the video <a href="https://www.youtube.com/watch?v=uWGUoMbv-VA">notsofantastic</a></i>
</div>

The obvious assumption would be that this is an intentional feature that uses things like the slope of the surface and the player's velocity to determine when a player is rampsliding, but that is not the case. In fact, in the same way that bunnyhopping was likely an unintentional quirk of the 'air acceleration' code, rampsliding was likely an unintentional quirk of the 'categorize position' code.

In [Quake's `PM_CatagorizePosition` \[sic\] function, we see the following code](https://github.com/id-Software/Quake/blob/bf4ac424ce754894ac8f1dae6a3981954bc9852d/QW/client/pmove.c#L587-L590):

```language-c
if (pmove.velocity[2] > 180)
{
	onground = -1;
}
```

That is, if the player is moving up (velocity index 2 is the vertical component) at greater than 180 units, then the player is automatically considered in the air, and this overrides all other 'on ground' checks. With this, if a player is colliding with a ramp such that their velocity along the ramp has a large enough vertical component, then they are considered in the air, and thus ground friction is simply not applied (specifically, `PM_AirMove` is called instead of `PM_GroundMove`).

This creates two emergent conditions for rampsliding:

- The ramp can't be too shallow
- The player can't be going too slow

And these two conditions also interact with eachother (e.g. you can slide a shallower ramp when you're going faster).

<div style="text-align: center;">
	<style scoped>
		#velocity-example {
			margin-right: auto; margin-left: auto; display: block;
			width: 500px; height: 400px;
			position: relative;
			background-color: #eee;
			overflow: hidden;
		}
		#velocity-slope {
			position: absolute;
			bottom: 30px;
			right: 50px;
			width: 400px;
			height: 5px;
			background-color: black;
			transform-origin: 100% 100%;
			transform: rotate(30deg);
		}
		#velocity-slope-angle {
			position: absolute;
			bottom: 35px;
			left: 60px;
		}
		#velocity-slope-angle-circle {
			position: absolute;
			overflow: hidden;
			padding: 0; margin: 0;
			width: 400px; height: 400px;
			right: 50px; bottom: 30px;
		}
		#velocity-slope-angle-circle > div {
			position: absolute;
			border: dashed 1px rgba(0,0,0,0.5);
			border-right: 0; border-bottom: 0;
			width: 399px; height: 399px;
			right: 0px; bottom: 0px;
			border-radius: 100% 0 0 0;
			transform-origin: 100% 100%;
			transform: rotate(-60deg);
		}
		#velocity-ground {
			position: absolute;
			bottom: 30px;
			right: 50px;
			width: 400px;
			height: 1px;
			background-color: rgba(0,0,0,0.5);
		}
		#velocity-arrow {
			position: absolute;
			bottom: 30px;
			right: 50px;
			width: 200px;
			height: 3px;
			transform-origin: 100% 5px;
			transform: rotate(30deg) translate(-100px, -20px);
			background-color: black;
			z-index: 5;
		}
		.rampsliding #velocity-arrow {
			background-color: #69A9CE;
		}
		#velocity-arrow::after { 
	    content: '';
	    width: 0; 
	    height: 0; 
	    border-top: 5px solid transparent;
	    border-bottom: 5px solid transparent;
	    border-right: 20px solid black;
	    position: absolute;
	    left: 0px;
	    top: -4px;
			z-index: 5;
		}
		.rampsliding #velocity-arrow::after {
			border-right-color: #69A9CE;
		}
		#velocity-magnitude {
			position: absolute;
			left: 50%;
			bottom: 0em;
			font-size: 90%;
			transform: translate(-50%, 0);
		}
		#velocity-components {
			position: absolute;
			border-right: 1px dashed;
			border-top: 1px dashed;
			border-color: rgba(0,0,0,.5);
			z-index: 4;
			left: 201.767px; bottom: 97.317px;
			width: 174.367px; height: 103.183px;
		}
		#velocity-x {
			position:absolute;
			text-align: center;
			top: -2em;
			left: 50%;
			transform: translate(-50%, 0);
		}
		#velocity-y {
			position:absolute;
			left: 100%;
			margin-left: 1em;
			top: 50%;
			transform: translate(0, -50%);
			text-align: left;
			color: red;
			font-weight: bold;
		}
		.rampsliding #velocity-y {
			color: green;
		}
		#velocity-status {
			position:absolute;
			left: 0px; right: 0px; top: 1em;
			text-align: center;
		}
	</style>
	<script>
		/* jshint esversion: 6 */
		(function() {
			function startAnimation(options) {
				let start = performance.now();

				requestAnimationFrame(function animate(time) {
					// timeFraction goes from 0 to 1
					let timeFraction = (time - start) / options.duration;
					if (timeFraction > 1) timeFraction = 1;

					// calculate the current animation state
					let progress = options.timing(timeFraction);
					if (progress < 0) {
						return;
					}

					options.draw(progress); // draw it

					if (timeFraction < 1) {
						requestAnimationFrame(animate);
					} else if (options.next) {
						startAnimation(options.next);
					}
				});
			}
			var ready = function() {
				var container = document.getElementById('velocity-example');
				var slope = document.getElementById('velocity-slope');
				var slopeAngle = document.getElementById('velocity-slope-angle');
				var slopeAngleCircle = document.getElementById('velocity-slope-angle-circle').firstElementChild;
				var arrow = document.getElementById('velocity-arrow');
				var velocityComponents = document.getElementById('velocity-components');
				var curMagnitude = 700;
				var curAngle = 30;
				var cancelAnimation = false;

				var update = function(degrees, magnitude) {
					curAngle = degrees;
					curMagnitude = magnitude;
					var radians = degrees / 180 * Math.PI;
					
					slope.style.transform = 'rotate(' + degrees + 'deg)';
					slopeAngle.innerHTML = Math.round(degrees) + "&deg;"; 
					var circleAngle = -(90 - degrees);
					slopeAngleCircle.style.transform = 'rotate(' + circleAngle + 'deg)';

					arrow.style.width = (magnitude / 3.5) + 'px';
					arrow.style.transform = 'rotate(' + degrees + 'deg) translate(-100px, -20px)';
					arrowBounds = arrow.getBoundingClientRect();
					containerBounds = container.getBoundingClientRect();
					velocityComponents.style.left = (arrowBounds.left-containerBounds.left)+'px';
					velocityComponents.style.bottom = Math.abs(arrowBounds.bottom-containerBounds.bottom)+'px';
					velocityComponents.style.width = (arrowBounds.right-arrowBounds.left)+'px';
					velocityComponents.style.height = Math.abs(arrowBounds.top-arrowBounds.bottom)+'px';

					var x = Math.cos(radians) * magnitude;
					var y = Math.sin(radians) * magnitude;
					document.getElementById('velocity-x').innerHTML = Math.round(x);
					document.getElementById('velocity-y').innerHTML = Math.round(y);
					document.getElementById('velocity-magnitude').innerHTML = Math.round(magnitude);

					var rampsliding = y > 180;
					if (rampsliding) {
						container.classList.add('rampsliding');
						document.getElementById('velocity-status').innerHTML = "player state: 'in air'";
					} else {
						container.classList.remove('rampsliding');
						document.getElementById('velocity-status').innerHTML = "player state: 'on ground'";
					}
				};

				container.addEventListener('mousemove', e => {
					cancelAnimation = true;
					var slopeRect = slope.getBoundingClientRect();
					var anchorX = window.scrollX + slopeRect.right;
					var anchorY = window.scrollY + slopeRect.bottom;
					var radians = Math.atan2(-(e.pageY - anchorY), -(e.pageX - anchorX));
					var degrees = radians * 180 / Math.PI;
					degrees = Math.max(5, Math.min(degrees, 50));
					update(degrees, curMagnitude);
				});

				var thirtyToTen = {
					duration: 2000,
					timing: function(timeFraction) { return cancelAnimation ? -1 : timeFraction; },
					draw: function(progress) {
						update(30 - 20 * Math.min(1, 1.5 * progress), curMagnitude);
					}
				};
				var tenToTwenty = {
					duration: 1000,
					timing: function(timeFraction) { return cancelAnimation ? -1 : timeFraction; },
					draw: function(progress) {
						update(10 + 10 * progress, curMagnitude);
					}
				};
				var magnitudeAnimDown = {
					duration: 2000,
					timing: function(timeFraction) { return cancelAnimation ? -1 : timeFraction; },
					draw: function(progress) {
						update(20, 700 - 300 * Math.min(1, 1.5 * progress));
					}
				};
				var magnitudeAnimUp = {
					duration: 2000,
					timing: function(timeFraction) { return cancelAnimation ? -1 : timeFraction; },
					draw: function(progress) {
						update(20, 400 + 300 * progress);
					}
				};
				var twentyToTen = {
					duration: 1500,
					timing: function(timeFraction) { return cancelAnimation ? -1 : timeFraction; },
					draw: function(progress) {
						update(20 - 10 * Math.min(1, 1.5 * progress), curMagnitude);
					}
				};
				thirtyToTen.next = tenToTwenty;
				tenToTwenty.next = magnitudeAnimDown;
				magnitudeAnimDown.next = magnitudeAnimUp;
				magnitudeAnimUp.next = twentyToTen;
				twentyToTen.next = tenToTwenty;
				startAnimation(thirtyToTen);
			};
			if (document.readyState == 'complete' || document.readyState == 'loaded') {
				ready();
			} else {
				window.addEventListener('DOMContentLoaded', ready);
			}
		})();
	</script>
	<div id="velocity-example" class="rampsliding">
		<div id="velocity-slope"></div>
		<div id="velocity-ground"></div>
		<div id="velocity-slope-angle">30&deg;</div>
		<div id="velocity-slope-angle-circle"><div></div></div>
		<div id="velocity-arrow" class="rampsliding">
			<div id="velocity-magnitude">700</div>
		</div>
		<div id="velocity-components">
			<div id="velocity-x">606</div>
			<div id="velocity-y">350</div>
		</div>
		<div id="velocity-status">player state: 'in air'</div>
	</div>
	<i style="background-color: rgba(0,0,0, .1); margin:0; padding: .25em;">Mouse over the diagram to interact with it</i>
</div>

Similar code exists [in the Half-Life (GoldSrc) engine](https://github.com/ValveSoftware/halflife/blob/c76dd531a79a176eef7cdbca5a80811123afbbe2/pm_shared/pm_shared.c#L1563-L1566):

```language-c
if (pmove->velocity[2] > 180)   // Shooting up really fast.  Definitely not on ground.
{
	pmove->onground = -1;
}
```

and [in the Half-Life 2 (Source) engine](https://github.com/ValveSoftware/source-sdk-2013/blob/0d8dceea4310fde5706b3ce1c70609d72a38efdf/mp/src/game/shared/gamemovement.cpp#L3832-L3837):

```language-c
// Was on ground, but now suddenly am not
if ( bMovingUpRapidly || 
	( bMovingUp && player->GetMoveType() == MOVETYPE_LADDER ) )   
{
	SetGroundEntity( NULL );
}
```

## Why would this code exist?

It seems like this code is mostly a catch-all fix to resolve any instance where a player is moved by an external force that *should* push them off the ground, but that doesn't directly alter the player's 'on ground' flag--things like explosions, or `trigger_push` brush entities. This is necessary because the 'on ground' and 'in air' states are handled very differently: for example, when on the ground, the player's vertical velocity is set to zero every frame.

## Why do you still slow down while rampsliding?

Stuff about `ClipVelocity` here. [Experimental adjustable rampslide 'friction' implementation from the FF beta way back when for reference](https://github.com/fortressforever/fortressforever/blob/dev/svn/game_shared/gamemovement.cpp#L2742-L2769).

## What about surfing (like in [Counter-Strike surf maps](https://www.youtube.com/watch?v=hMsPf8eSW3k))?

Surfing comes from a separate but related mechanism. If a surface is steep enough, then the player is *always* considered 'in the air' when colliding with it.
