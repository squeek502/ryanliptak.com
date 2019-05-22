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
		.rampsliding-diagram {
			margin-right: auto; margin-left: auto; display: block;
			width: 500px; height: 400px;
			position: relative;
			background-color: #eee;
			overflow: hidden;
		}
		.rampsliding-diagram .slope {
			position: absolute;
			bottom: 30px;
			right: 50px;
			width: 400px;
			height: 5px;
			background-color: black;
			transform-origin: 100% 100%;
			transform: rotate(30deg);
		}
		.rampsliding-diagram .slope-angle {
			position: absolute;
			bottom: 35px;
			left: 60px;
		}
		.rampsliding-diagram .slope-angle-circle {
			position: absolute;
			overflow: hidden;
			padding: 0; margin: 0;
			width: 400px; height: 400px;
			right: 50px; bottom: 30px;
			z-index: 0;
			pointer-events: none;
		}
		.rampsliding-diagram .slope-angle-circle > div {
			position: absolute;
			border: dashed 1px rgba(0,0,0,0.5);
			border-right: 0; border-bottom: 0;
			width: 399px; height: 399px;
			right: 0px; bottom: 0px;
			border-radius: 100% 0 0 0;
			transform-origin: 100% 100%;
			transform: rotate(-60deg);
			z-index: 0;
			pointer-events: none;
		}
		.rampsliding-diagram .ground {
			position: absolute;
			bottom: 30px;
			right: 50px;
			width: 400px;
			height: 1px;
			background-color: rgba(0,0,0,0.5);
		}
		.rampsliding-diagram .velocity-arrow {
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
		.rampsliding-diagram.rampsliding .velocity-arrow {
			background-color: #69A9CE;
		}
		.rampsliding-diagram .velocity-arrow::after { 
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
		.rampsliding-diagram.rampsliding .velocity-arrow::after {
			border-right-color: #69A9CE;
		}
		.rampsliding-diagram .velocity-magnitude {
			position: absolute;
			left: 50%;
			bottom: 0em;
			font-size: 90%;
			transform: translate(-50%, 0);
		}
		.rampsliding-diagram .velocity-components {
			position: absolute;
			border-right: 1px dashed;
			border-top: 1px dashed;
			border-color: rgba(0,0,0,.5);
			z-index: 4;
			left: 201.767px; bottom: 97.317px;
			width: 174.367px; height: 103.183px;
		}
		.rampsliding-diagram .velocity-x {
			position:absolute;
			text-align: center;
			top: -2em;
			left: 50%;
			transform: translate(-50%, 0);
		}
		.rampsliding-diagram .velocity-y {
			position:absolute;
			left: 100%;
			margin-left: 1em;
			top: 50%;
			transform: translate(0, -50%);
			text-align: left;
			color: red;
			font-weight: bold;
		}
		.rampsliding-diagram.rampsliding .velocity-y {
			color: green;
		}
		.rampsliding-diagram .status {
			position:absolute;
			left: 0px; right: 0px; top: 1em;
			text-align: center;
		}
	</style>
	<div id="velocity-example" class="rampsliding-diagram rampsliding">
		<div class="slope"></div>
		<div class="ground"></div>
		<div class="slope-angle">30&deg;</div>
		<div class="slope-angle-circle"><div></div></div>
		<div class="velocity-arrow">
			<div class="velocity-magnitude">700</div>
		</div>
		<div class="velocity-components">
			<div class="velocity-x">606</div>
			<div class="velocity-y">350</div>
		</div>
		<div class="status">player state: 'in air'</div>
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

## So then why do you slow down while rampsliding?

When a player collides with a surface, the resulting velocity is determined using a function called [`PM_ClipVelocity`](https://github.com/id-Software/Quake/blob/bf4ac424ce754894ac8f1dae6a3981954bc9852d/QW/client/pmove.c#L72-L95). The following is a simplified version of the `ClipVelocity` logic:

```language-c
float backoff = DotProduct(velocity, surfaceNormal);

for (i=0; i<3; i++)
{
	float change = surfaceNormal[i] * backoff;
	velocity[i] = velocity[i] - change;
}
```

Stuff about `ClipVelocity` here. [Experimental adjustable rampslide 'friction' implementation from the FF beta way back when for reference](https://github.com/fortressforever/fortressforever/blob/dev/svn/game_shared/gamemovement.cpp#L2742-L2769).

<div style="text-align: center;">
	<style scoped>
		.rampsliding-diagram .normal-arrow {
			position: absolute;
			bottom: 30px;
			right: 50px;
			width: 50px;
			height: 2px;
			transform-origin: 100% 2px;
			transform: rotate(120deg) translate(-4px, 400px);
			background-color: #8E78B5;
			z-index: 3;
		}
		.rampsliding-diagram .normal-arrow::after { 
			content: '';
			width: 0; 
			height: 0; 
			border-top: 5px solid transparent;
			border-bottom: 5px solid transparent;
			border-right: 20px solid #8E78B5;
			position: absolute;
			left: 0px;
			top: -4px;
			z-index: 3;
		}
		.rampsliding-diagram .normal-components {
			position: absolute;
			border-left: 1px dashed;
			border-top: 1px dashed;
			border-color: rgba(0,0,0,.5);
			z-index: 4;
			left: 105.583px; bottom: 232.467px;
			width: 26.7333px; height: 44.3px;
		}
		.rampsliding-diagram .normal-x {
			position:absolute;
			text-align: center;
			top: -2em;
			left: 50%;
			transform: translate(-50%, 0);
		}
		.rampsliding-diagram .normal-y {
			position:absolute;
			right: 100%;
			margin-right: .75em;
			top: 50%;
			transform: translate(0, -50%);
			text-align: right;
		}
		.rampsliding-diagram .controls.step {
			padding: 0.5em; margin: 0.5em;
			cursor: pointer;
			background-color: rgba(0,0,0,.1);
			display: inline-block;
			position: absolute;
			left: 0; top: 0;
		}
	</style>
	<div id="clipvelocity-example" class="rampsliding-diagram rampsliding">
		<div class="slope"></div>
		<div class="ground"></div>
		<div class="slope-angle">30&deg;</div>
		<div class="slope-angle-circle"><div></div></div>
		<div class="normal-arrow"></div>
		<div class="normal-components">
			<div class="normal-x">0.50</div>
			<div class="normal-y">0.87</div>
		</div>
		<div class="velocity-arrow">
			<div class="velocity-magnitude">700</div>
		</div>
		<div class="velocity-components">
			<div class="velocity-x">606</div>
			<div class="velocity-y">350</div>
		</div>
		<div class="controls step">Step</div>
		<div class="info">
			<div>Backoff: <span class="backoff"></span></div>
			<div>Change: <span class="change"></span></div>
			<div>Prev Velocity: <span class="prev-velocity"></span></div>
		</div>
	</div>
	<i style="background-color: rgba(0,0,0, .1); margin:0; padding: .25em;">Mouse over the diagram to interact with it</i>
</div>

## What about surfing (like in [Counter-Strike surf maps](https://www.youtube.com/watch?v=hMsPf8eSW3k))?

Surfing comes from a separate but related mechanism. If a surface is steep enough, then the player is *always* considered 'in the air' when colliding with it.

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

		class RampslideDiagram {

			constructor(root, onupdate) {
				this.root = root;
				this.onupdate = onupdate;
				this.slope = root.querySelector('.slope');
				this.slopeAngle = root.querySelector('.slope-angle');
				this.slopeAngleCircle = root.querySelector('.slope-angle-circle').firstElementChild;
				this.velocityArrow = root.querySelector('.velocity-arrow');
				this.velocityComponents = root.querySelector('.velocity-components');
				this.velocityX = root.querySelector('.velocity-x');
				this.velocityY = root.querySelector('.velocity-y');
				this.velocityMagnitude = root.querySelector('.velocity-magnitude');
				this.status = root.querySelector('.status');
				this.magnitude = 700;
				this.angle = 30;
			}

			getVelocity() {
				let radians = this.angle / 180 * Math.PI;
				let x = Math.cos(radians) * this.magnitude;
				let y = Math.sin(radians) * this.magnitude;
				// reverse x so that we're moving left
				return new Vec2d(-x, y);
			}

			getSurfaceNormal() {
				let radians = this.angle / 180 * Math.PI;
				let x = Math.sin(radians);
				let y = Math.cos(radians);
				return new Vec2d(x, y).normalize();
			}

			update() {
				let velocity = this.getVelocity();
				
				this.slope.style.transform = 'rotate(' + this.angle + 'deg)';
				this.slopeAngle.innerHTML = Math.round(this.angle) + "&deg;"; 
				let circleAngle = -(90 - this.angle);
				this.slopeAngleCircle.style.transform = 'rotate(' + circleAngle + 'deg)';

				this.velocityArrow.style.width = (this.magnitude / 3.5) + 'px';
				this.velocityArrow.style.transform = 'rotate(' + this.angle + 'deg) translate(-100px, -20px)';
				let arrowBounds = this.velocityArrow.getBoundingClientRect();
				let containerBounds = this.root.getBoundingClientRect();
				this.velocityComponents.style.left = (arrowBounds.left-containerBounds.left)+'px';
				this.velocityComponents.style.bottom = Math.abs(arrowBounds.bottom-containerBounds.bottom)+'px';
				this.velocityComponents.style.width = (arrowBounds.right-arrowBounds.left)+'px';
				this.velocityComponents.style.height = Math.abs(arrowBounds.top-arrowBounds.bottom)+'px';

				this.velocityX.innerHTML = Math.abs(Math.round(velocity.x));
				this.velocityY.innerHTML = Math.round(velocity.y);
				this.velocityMagnitude.innerHTML = Math.round(this.magnitude);

				let prevRampsliding = this.rampsliding;
				this.rampsliding = velocity.y > 180;
				if (this.rampsliding !== prevRampsliding) {
					if (this.rampsliding) {
						this.root.classList.add('rampsliding');
						if (this.status) {
							this.status.innerHTML = "player state: 'in air'";
						}
					} else {
						this.root.classList.remove('rampsliding');
						if (this.status) {
							this.status.innerHTML = "player state: 'on ground'";
						}
					}
				}

				if (this.onupdate) {
					this.onupdate(this);
				}
			}
		}

		class Vec2d {
			constructor(x, y) {
				this.x = x ? x : 0;
				this.y = y ? y : 0;
			}

			dot(other) {
				return this.x * other.x + this.y * other.y;
			}

			length() {
				return Math.sqrt(this.x*this.x + this.y*this.y);
			}

			normalize() {
				let length = this.length();
				return new Vec2d(this.x/length, this.y/length);
			}
		}

		let initDiagram1 = function() {
			let diagram1 = new RampslideDiagram(document.getElementById('velocity-example'));
			let cancelAnimation = false;

			diagram1.root.addEventListener('mousemove', e => {
				cancelAnimation = true;
				let slopeRect = diagram1.slope.getBoundingClientRect();
				let anchorX = window.scrollX + slopeRect.right;
				let anchorY = window.scrollY + slopeRect.bottom;
				let radians = Math.atan2(-(e.pageY - anchorY), -(e.pageX - anchorX));
				let degrees = radians * 180 / Math.PI;
				degrees = Math.max(5, Math.min(degrees, 50));
				diagram1.angle = degrees;
				diagram1.update();
			});

			let timing = function(timeFraction) { return cancelAnimation ? -1 : timeFraction; };
			let thirtyToTen = { duration: 2000, timing,
				draw: function(progress) {
					diagram1.angle = 30 - 20 * Math.min(1, 1.5 * progress);
					diagram1.update();
				}
			};
			let tenToTwenty = { duration: 1000, timing,
				draw: function(progress) {
					diagram1.angle = 10 + 10 * progress;
					diagram1.update();
				}
			};
			let magnitudeAnimDown = { duration: 2500, timing,
				draw: function(progress) {
					diagram1.magnitude = 700 - 300 * Math.min(1, 1.5 * progress);
					diagram1.update();
				}
			};
			let magnitudeAnimUp = { duration: 2000, timing,
				draw: function(progress) {
					diagram1.magnitude = 400 + 300 * progress;
					diagram1.update();
				}
			};
			let twentyToTen = { duration: 1500, timing,
				draw: function(progress) {
					diagram1.angle = 20 - 10 * Math.min(1, 1.5 * progress);
					diagram1.update();
				}
			};
			thirtyToTen.next = tenToTwenty;
			tenToTwenty.next = magnitudeAnimDown;
			magnitudeAnimDown.next = magnitudeAnimUp;
			magnitudeAnimUp.next = twentyToTen;
			twentyToTen.next = tenToTwenty;
			startAnimation(thirtyToTen);
		};

		let initDiagram2 = function() {
			let diagram2 = new RampslideDiagram(document.getElementById('clipvelocity-example'));

			let clipVelocity = function(velocity, normal) {
				let backoff = velocity.dot(normal);
				let changeX = normal.x * backoff;
				let changeY = normal.y * backoff;
				return {
					backoff, changeX, changeY,
					velocity: new Vec2d(
						velocity.x - changeX,
						velocity.y - changeY
					)
				};
			};

			let surfaceNormalArrow = diagram2.root.querySelector('.normal-arrow');
			let surfaceNormalComponents = diagram2.root.querySelector('.normal-components');
			let surfaceNormalX = diagram2.root.querySelector('.normal-x');
			let surfaceNormalY = diagram2.root.querySelector('.normal-y');
			var stepButton = diagram2.root.querySelector('.controls.step');
			diagram2.onupdate = function() {
				surfaceNormalArrow.style.transform = 'rotate('+(Math.round(this.angle)+90)+'deg) translate(-4px, 400px)';

				let normal = diagram2.getSurfaceNormal();
				let arrowBounds = surfaceNormalArrow.getBoundingClientRect();
				let containerBounds = this.root.getBoundingClientRect();
				surfaceNormalComponents.style.left = (arrowBounds.left-containerBounds.left)+'px';
				surfaceNormalComponents.style.bottom = Math.abs(arrowBounds.bottom-containerBounds.bottom)+'px';
				surfaceNormalComponents.style.width = (arrowBounds.right-arrowBounds.left)+'px';
				surfaceNormalComponents.style.height = Math.abs(arrowBounds.top-arrowBounds.bottom)+'px';
				surfaceNormalX.innerHTML = normal.x.toFixed(2);
				surfaceNormalY.innerHTML = normal.y.toFixed(2);
			}.bind(diagram2);

			stepButton.addEventListener('click', e => {
				let velocity = diagram2.getVelocity();
				let clipped = clipVelocity(velocity, diagram2.getSurfaceNormal());
				diagram2.magnitude = clipped.velocity.length();
				diagram2.update();

				diagram2.root.querySelector('.info .backoff').innerHTML = clipped.backoff;
				diagram2.root.querySelector('.info .change').innerHTML = clipped.changeX + ", " + clipped.changeY;
				diagram2.root.querySelector('.info .prev-velocity').innerHTML = Math.round(Math.abs(velocity.x)) + ", " + Math.round(velocity.y);
			});

			//diagram2.update();

/*
			diagram2.root.addEventListener('mousemove', e => {
				cancelAnimation = true;
				let slopeRect = diagram2.slope.getBoundingClientRect();
				let anchorX = window.scrollX + slopeRect.right;
				let anchorY = window.scrollY + slopeRect.bottom;
				let radians = Math.atan2(-(e.pageY - anchorY), -(e.pageX - anchorX));
				let degrees = radians * 180 / Math.PI;
				degrees = Math.max(5, Math.min(degrees, 50));
				diagram2.angle = degrees;
				diagram2.update();
			});
*/
/*			setInterval(function() {
				let clipped = clipVelocity(diagram2.getVelocity(), diagram2.getSurfaceNormal());
				diagram2.magnitude = clipped.velocity.length();
				diagram2.update();
			}, 1000);*/
		};

		let ready = function() {
			initDiagram1();
			initDiagram2();
		};
		if (document.readyState == 'complete' || document.readyState == 'loaded') {
			ready();
		} else {
			window.addEventListener('DOMContentLoaded', ready);
		}
	})();
</script>
