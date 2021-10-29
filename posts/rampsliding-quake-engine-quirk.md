In Quake and derivative engines (like Half-Life 1 & 2), it is possible to slide up sloped surfaces without losing much speed. This is a major gameplay component of games like *QuakeWorld Team Fortress*, *Team Fortress Classic*, and [*Fortress Forever*](http://www.fortress-forever.com), where maintaining momentum from large speed bursts is fundamental.

<div style="text-align: center;">
<video autoplay loop muted style="margin-left:auto; margin-right:auto; display: block;">
	<source src="/images/rampsliding-quake-engine-quirk/rampslide.mp4" type="video/mp4">
</video>
<i class="caption">Rampsliding in Team Fortress Classic from the video <a href="https://www.youtube.com/watch?v=uWGUoMbv-VA">notsofantastic</a></i>
</div>

The obvious assumption would be that this is an intentional feature that uses things like the slope of the surface and the player's velocity to determine when a player is rampsliding, but that is not the case. In fact, in the same way that bunnyhopping was likely [an unintentional quirk of the 'air acceleration' code](https://flafla2.github.io/2015/02/14/bunnyhop.html), rampsliding was likely an unintentional quirk of the 'categorize position' code.

In [Quake's `PM_CatagorizePosition` \[sic\] function, we see the following code](https://github.com/id-Software/Quake/blob/bf4ac424ce754894ac8f1dae6a3981954bc9852d/QW/client/pmove.c#L587-L590):

```language-c
if (pmove.velocity[2] > 180)
{
	onground = -1;
}
```

That is, if the player is ever moving up at greater than 180 units (velocity index 2 is the vertical component), then the player is automatically considered 'in the air,' and this overrides all other 'on ground' checks. With this, if a player is colliding with a ramp such that their velocity along the ramp has a large enough vertical component, then they are considered in the air, and thus ground friction is simply not applied (specifically, `PM_AirMove` is called instead of `PM_GroundMove`).

This creates two emergent conditions for rampsliding:

- The ramp can't be too shallow
- The player can't be going too slow

And these two conditions also interact with eachother (e.g. you can slide a shallower ramp when you're going faster).

<div style="text-align: center;">
	<div id="velocity-example" class="rampsliding-diagram rampsliding">
		<div class="slope"></div>
		<div class="ground"></div>
		<div class="slope-angle">30&deg;</div>
		<div class="slope-angle-circle"><div></div></div>
		<div class="slope-angle-lock unlocked" style="display:none"></div>
		<div class="velocity-arrow-container">
			<div class="velocity-arrow">
				<div class="velocity-magnitude">700</div>
			</div>
		</div>
		<div class="velocity-components">
			<div class="velocity-x">606</div>
			<div class="velocity-y">350</div>
		</div>
		<div class="status">player state: 'in air'</div>
	</div>
	<i class="caption">Mouse over the diagram to interact with it</i>
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

It seems like this code is mostly a catch-all fix to resolve any instance where a player is moved by an external force that *should* push them off the ground, but that doesn't directly alter the player's 'on ground' flag--things like explosions, or `trigger_push` brush entities. This is necessary because the 'on ground' and 'in air' states are handled very differently: for example, when on the ground, [the player's vertical velocity is set to zero every frame](https://github.com/id-Software/Quake/blob/bf4ac424ce754894ac8f1dae6a3981954bc9852d/QW/client/pmove.c#L541), so things like RPG explosions would otherwise never be able to push a player off the ground.

## If there's no friction, why do you slow down while rampsliding?

When a player collides with a surface, the resulting velocity is determined using [a function called `PM_ClipVelocity`](https://github.com/id-Software/Quake/blob/bf4ac424ce754894ac8f1dae6a3981954bc9852d/QW/client/pmove.c#L72-L95). The following is a simplified version of the `ClipVelocity` logic:

```language-c
float backoff = DotProduct(velocity, surfaceNormal);

for (i=0; i<3; i++)
{
	float change = surfaceNormal[i] * backoff;
	velocity[i] = velocity[i] - change;
}
```

Its job is to make velocity parallel to the surface that is being collided with. If the velocity is not already close to parallel, then non-negligible speed loss can result from `ClipVelocity`, but once velocity *is* parallel to the surface, running it through the function again will have no effect. `ClipVelocity` therefore is responsible for speed loss when first colliding with a slope, and makes it so that the angle of your velocity entering the ramp matters for how much speed you ultimately maintain, but it does not explain speed loss *while* rampsliding.

<div style="text-align: center;">
	<div id="clipvelocity-enter-example" class="rampsliding-diagram">
		<div class="slope"></div>
		<div class="ground"></div>
		<div class="slope-angle">30&deg;</div>
		<div class="slope-angle-circle"><div></div></div>
		<div class="velocity-arrow-container">
			<div class="velocity-arrow">
				<div class="velocity-magnitude">495</div>
			</div>
		</div>
		<div class="velocity-arrow-enter-container">
			<div class="velocity-arrow">
				<div class="velocity-magnitude">700</div>
			</div>
		</div>
		<div class="status-clipvelocity">velocity maintained during ClipVelocity: 71%</div>
	</div>
	<i class="caption">Speed loss due to ClipVelocity at different approach angles</i>
</div>

This is where gravity comes into the picture: because you are considered 'in the air' while rampsliding, gravity is applied every frame. This creates a loop that goes like this:

- Try to move along a surface
- `ClipVelocity` to make velocity parallel to the surface
- Move along the surface using the adjusted velocity
- Apply gravity by subtracting from the vertical component of velocity, making the velocity no longer parallel to the surface
- Repeat

In this loop, `ClipVelocity` basically serves to redistribute changes in velocity among all of its components.

<div style="text-align: center;">
	<div id="clipvelocity-example" class="rampsliding-diagram rampsliding">
		<div class="slope"></div>
		<div class="ground"></div>
		<div class="slope-angle">30&deg;</div>
		<div class="slope-angle-circle"><div></div></div>
		<div class="velocity-arrow-container">
			<div class="velocity-arrow">
				<div class="velocity-magnitude">700</div>
			</div>
		</div>
		<div class="velocity-components">
			<div class="velocity-x">606</div>
			<div class="velocity-y">350</div>
		</div>
		<ul class="steps">
			<li class="clip-velocity current">Clip Velocity</li>
			<li class="move">Move</li>
			<li class="gravity">Apply Gravity</li>
		</ul>
		<div class="gravity-controls">
			<label for="gravity">Gravity (per loop):</label>
			<input type="text" value="25" name="gravity" size="4" />
		</div>
	</div>
	<i class="caption">Note that with gravity <= 25, velocity's magnitude only changes in the 'Apply Gravity' phase</i>
</div>

So, if you are rampsliding on a constant slope, *all speed loss is typically due to gravity*. If you set gravity to 0, you can rampslide infinitely, and if you set gravity really high, you can only rampslide for a second or two. This makes sense if you think of rampsliding in terms of an object sliding up a completely frictionless slope: the force that will make that object eventually stop and start sliding back down the slope is gravity.

## What about surfing (like in [Counter-Strike surf maps](https://www.youtube.com/watch?v=hMsPf8eSW3k))?

Surfing comes from a separate but related mechanism: if a surface is steep enough, then the player is *always* considered 'in the air' when colliding with it. The speed gain while surfing comes from two places:

- The same interaction with `ClipVelocity` described above makes you gain speed from gravity when moving down a slope
- [`AirAccelerate` allows you to gain a bit more horizontal speed](https://flafla2.github.io/2015/02/14/bunnyhop.html) (when done right), and to control your position on the slope

## Wrapping up

It's pretty remarkable to note that almost every movement technique in games like Team Fortress Classic and Fortress Forever was originally accidental:

- Bunnyhopping was an unintentional feature spawned from how acceleration was implemented
- Rampsliding was an unintentional feature spawned from a fix for a completely unrelated 'stuck on the ground' bug
- Concussion grenades were intended to displace/disorient the enemy team, [but they got used to boost yourself instead](https://youtu.be/AA7ytpUN2so?t=21) and [form the basis of TFC/FF's high-speed offense](https://youtu.be/BPZsL6R0uq0?t=168)

Even more remarkable is that this phenomenon is actually somewhat common in games, where unintended mechanics become fundamental to the gameplay as we know it today (see things like [mutalisk micro in StarCraft](https://youtu.be/qVqrMqtaJPc?t=90), or [k-style in GunZ](https://www.youtube.com/watch?v=ppSU5xeEMdU), or even denying creeps in DotA).

---

### Addendum: Landing in front of a ramp instead of directly on it

After playing a game with rampsliding for a while, it becomes clear that if you land on a flat surface right before a ramp instead of directly on the ramp, you will often maintain more speed. This is due to how `ClipVelocity` works: you can maintain more speed after two calls of `ClipVelocity` with smaller angle differentials than after a single call with a larger angle differential.

<div style="text-align: center;">
	<div id="clipvelocity-addendum-1" class="rampsliding-diagram">
		<div class="slope"></div>
		<div class="flat"></div>
		<div class="ground"></div>
		<div class="slope-angle">30&deg;</div>
		<div class="slope-angle-circle"><div></div></div>
		<div class="velocity-arrow-container">
			<div class="velocity-arrow">
				<div class="velocity-magnitude">350</div>
			</div>
		</div>
		<div class="velocity-arrow-enter-container">
			<div class="velocity-arrow">
				<div class="velocity-magnitude">700</div>
			</div>
		</div>
	</div>
	<div id="clipvelocity-addendum-2" class="rampsliding-diagram">
		<div class="slope"></div>
		<div class="flat"></div>
		<div class="ground"></div>
		<div class="slope-angle">30&deg;</div>
		<div class="slope-angle-circle"><div></div></div>
		<div class="velocity-arrow-container">
			<div class="velocity-arrow">
				<div class="velocity-magnitude">525</div>
			</div>
		</div>
		<div class="velocity-arrow-intermediate-container">
			<div class="velocity-arrow">
				<div class="velocity-magnitude">606</div>
			</div>
		</div>
		<div class="velocity-arrow-enter-container">
			<div class="velocity-arrow">
				<div class="velocity-magnitude">700</div>
			</div>
		</div>
		<div class="status-clipvelocity">increased % velocity maintained from landing on flat: 50%</div>
	</div>
	<i class="caption">Comparison of landing on the ramp directly vs. landing right in front of the ramp</i>
</div>

Note that in the above diagram, the velocity loss that would occur from friction when landing on the ground is not represented (i.e. the diagram is showing 'perfect' execution where you land *directly* in front of the ramp). In reality, the velocity maintained when landing on flat varies depending on how long you slide on the ground before hitting the ramp, since ground friction will be applied during that time.

<script>
	// this is mostly a sloppy mess
	/* jshint esversion: 6 */
	(function() {
		class RampslideDiagram {

			constructor(root, startingValues, onupdate) {
				this.root = root;
				this.onupdate = onupdate;
				this.slope = root.querySelector('.slope');
				this.slopeAngle = root.querySelector('.slope-angle');
				this.slopeAngleCircle = root.querySelector('.slope-angle-circle').firstElementChild;
				this.velocityArrowContainer = root.querySelector('.velocity-arrow-container');
				this.velocityArrow = this.velocityArrowContainer.querySelector('.velocity-arrow');
				this.velocityComponents = root.querySelector('.velocity-components');
				this.velocityX = root.querySelector('.velocity-x');
				this.velocityY = root.querySelector('.velocity-y');
				this.velocityMagnitude = this.velocityArrowContainer.querySelector('.velocity-magnitude');
				this.status = root.querySelector('.status');
				this.angle = startingValues.angle;
				this.magnitude = startingValues.magnitude;
				this.offset = startingValues.offset;
				this.alwaysParallel = startingValues.alwaysParallel;
				this.velocity = this.getVelocity(this.magnitude);
				this.scale = startingValues.scale || 3.5;
			}

			getVelocity(magnitude) {
				let radians = this.angle / 180 * Math.PI;
				let x = Math.cos(radians) * (magnitude || this.magnitude);
				let y = Math.sin(radians) * (magnitude || this.magnitude);
				// reverse x so that we're moving left
				return new Vec2d(-x, y);
			}

			getSurfaceNormal() {
				let radians = this.angle / 180 * Math.PI;
				let x = Math.sin(radians);
				let y = Math.cos(radians);
				return new Vec2d(x, y).normalize();
			}

			updateValues() {
				if (this.alwaysParallel) {
					this.velocityAngle = this.angle;
					this.velocity = this.getVelocity(this.magnitude);
				} else {
					this.magnitude = this.velocity.length();
					this.velocityAngle = 180 - Math.atan2(this.velocity.y, this.velocity.x) * 180 / Math.PI;
				}
			}

			updateSlope() {
				this.slope.style.transform = 'rotate(' + this.angle + 'deg)';
				this.slopeAngle.innerHTML = Math.round(this.angle) + "&deg;"; 
				let circleAngle = -(90 - this.angle);
				this.slopeAngleCircle.style.transform = 'rotate(' + circleAngle + 'deg)';
			}

			updateVelocity() {
				this.velocityArrowContainer.style.transform = 'rotate(' + this.angle + 'deg) translate(-'+Math.round(this.offset)+'px, -20px)';
				this.velocityArrow.style.width = (this.magnitude / this.scale) + 'px';
				this.velocityArrow.style.transform = 'rotate(' + (this.velocityAngle-this.angle) + 'deg)';
				let arrowBounds = this.velocityArrow.getBoundingClientRect();
				let containerBounds = this.root.getBoundingClientRect();
				if (this.velocityComponents) {
					this.velocityComponents.style.left = (arrowBounds.left-containerBounds.left)+'px';
					this.velocityComponents.style.bottom = Math.abs(arrowBounds.bottom-containerBounds.bottom)+'px';
					this.velocityComponents.style.width = (arrowBounds.right-arrowBounds.left)+'px';
					this.velocityComponents.style.height = Math.abs(arrowBounds.top-arrowBounds.bottom)+'px';
					this.velocityX.innerHTML = Math.abs(Math.round(this.velocity.x));
					this.velocityY.innerHTML = Math.round(this.velocity.y);
				}
				this.velocityMagnitude.innerHTML = Math.round(this.magnitude);
			}

			updateStatus() {
				let prevRampsliding = this.rampsliding;
				this.rampsliding = this.velocity.y > 180;
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
			}

			update() {
				this.updateValues();
				this.updateSlope();
				this.updateVelocity();
				this.updateStatus();

				if (this.onupdate) {
					this.onupdate(this);
				}
			}

			updateExcludeSlope() {
				this.updateValues();
				this.updateVelocity();
				this.updateStatus();

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
			sub(other) {
				return new Vec2d(this.x-other.x, this.y-other.y);
			}
		}

		let initDiagram1 = function() {
			let animationFrameRequest;
			function startAnimation(options) {
				let start = performance.now();

				animationFrameRequest = requestAnimationFrame(function animate(time) {
					// timeFraction goes from 0 to 1
					let timeFraction = (time - start) / options.duration;
					if (timeFraction > 1) timeFraction = 1;
					// the start can actually get a negative value for some reason
					// so clamp it
					if (timeFraction < 0) timeFraction = 0;

					// calculate the current animation state
					let progress = options.timing ? options.timing(timeFraction) : timeFraction;

					options.draw(progress); // draw it

					if (timeFraction < 1) {
						animationFrameRequest = requestAnimationFrame(animate);
					} else if (options.next) {
						startAnimation(options.next);
					}
				});
			}

			let diagram = new RampslideDiagram(
				document.getElementById('velocity-example'), 
				{angle: 30, magnitude: 700, offset: 100, alwaysParallel: true}
			);

			let timing = function(timeFraction) { return timeFraction; };
			let thirtyToTen = { duration: 2000, timing,
				draw: function(progress) {
					diagram.angle = 30 - 20 * Math.min(1, 1.5 * progress);
					diagram.update();
				}
			};
			let tenToTwenty = { duration: 1000, timing,
				draw: function(progress) {
					diagram.angle = 10 + 10 * progress;
					diagram.update();
				}
			};
			let magnitudeAnimDown = { duration: 2500, timing,
				draw: function(progress) {
					diagram.magnitude = 700 - 300 * Math.min(1, 1.5 * progress);
					diagram.updateExcludeSlope();
				}
			};
			let magnitudeAnimUp = { duration: 2000, timing,
				draw: function(progress) {
					diagram.magnitude = 400 + 300 * progress;
					diagram.updateExcludeSlope();
				}
			};
			let twentyToTen = { duration: 1500, timing,
				draw: function(progress) {
					diagram.angle = 20 - 10 * Math.min(1, 1.5 * progress);
					diagram.update();
				}
			};
			thirtyToTen.next = tenToTwenty;
			tenToTwenty.next = magnitudeAnimDown;
			magnitudeAnimDown.next = magnitudeAnimUp;
			magnitudeAnimUp.next = twentyToTen;
			twentyToTen.next = tenToTwenty;
			startAnimation(thirtyToTen);

			let lockButton = diagram.root.querySelector('.slope-angle-lock');
			let locked = false;
			lockButton.addEventListener('click', e => {
				locked = !locked;
				lockButton.classList.remove(locked ? 'unlocked' : 'locked');
				lockButton.classList.add(locked ? 'locked' : 'unlocked');
			});

			let prevLocked;
			let dragging = false;
			let originalTextCenter;
			let startingMagnitude;
			let startingVelocity;
			let dragHandler = function(e) {
				mousePos = new Vec2d(e.clientX, e.clientY);
				let delta = mousePos.sub(originalTextCenter);
				delta.y = -delta.y;
				let diff = startingVelocity.dot(delta);
				diagram.magnitude = startingMagnitude + diff/300;
				diagram.magnitude = Math.max(25, Math.min(2000, diagram.magnitude));
				diagram.updateExcludeSlope();
			};
			let resetDragging = function() {
				diagram.root.removeEventListener('mousemove', dragHandler);
				dragging = false;
			};
			diagram.velocityMagnitude.addEventListener('mousedown', e => {
				prevLocked = locked;
				locked = true;
				dragging = true;
				let textRect = diagram.velocityMagnitude.getBoundingClientRect();
				originalTextCenter = new Vec2d(
					(textRect.left + textRect.right) / 2,
					(textRect.top + textRect.bottom) / 2
				);
				startingMagnitude = diagram.magnitude;
				startingVelocity = diagram.getVelocity(startingMagnitude);
				diagram.root.addEventListener('mousemove', dragHandler);
				return false;
			});
			diagram.root.addEventListener('mouseup', e => {
				if (dragging) {
					resetDragging();
					locked = prevLocked;
					return false;
				}
			});

			diagram.root.addEventListener('mouseenter', e => {
				cancelAnimationFrame(animationFrameRequest);
				lockButton.style.display = 'block';
				diagram.magnitude = 700;
				locked = false;
				dragging = false;
			});
			diagram.root.addEventListener('mouseleave', e => {
				diagram.angle = 30;
				diagram.magnitude = 700;
				lockButton.style.display = 'none';
				resetDragging();
				startAnimation(thirtyToTen);
			});
			diagram.root.addEventListener('mousemove', e => {
				if (!locked) {
					let slopeRect = diagram.slope.getBoundingClientRect();
					let anchorX = window.scrollX + slopeRect.right;
					let anchorY = window.scrollY + slopeRect.bottom;
					let radians = Math.atan2(-(e.pageY - anchorY), -(e.pageX - anchorX));
					let degrees = radians * 180 / Math.PI;
					degrees = Math.max(5, Math.min(degrees, 45));
					diagram.angle = degrees;
					diagram.update();

					// the velocity vector parralel to the surface works as an offset
					// from the surface in the direction of the surface
					let offset = diagram.getVelocity(25);
					slopeRect = diagram.slope.getBoundingClientRect();
					let containerRect = diagram.root.getBoundingClientRect();
					let lockRect = lockButton.getBoundingClientRect();
					let lockW = lockRect.right - lockRect.left;
					let lockH = lockRect.bottom - lockRect.top;
					lockButton.style.left = (slopeRect.left - containerRect.left + offset.x - lockW/2) + 'px';
					lockButton.style.top = (slopeRect.top - containerRect.top - offset.y - lockH/2) + 'px';
				}
			});
		};

		let clipVelocity = function(velocity, normal) {
			let backoff = velocity.dot(normal);
			let changeX = normal.x * backoff;
			let changeY = normal.y * backoff;
			return new Vec2d(
				velocity.x - changeX,
				velocity.y - changeY
			);
		};
		let getVector = function(angle, magnitude) {
			let radians = angle / 180 * Math.PI;
			let x = Math.cos(radians) * magnitude;
			let y = Math.sin(radians) * magnitude;
			// reverse x so that we're moving left
			return new Vec2d(-x, y);
		};

		let initDiagram2 = function() {
			let animationFrameRequest;
			function startAnimation(options) {
				let start = performance.now();

				animationFrameRequest = requestAnimationFrame(function animate(time) {
					// timeFraction goes from 0 to 1
					let timeFraction = (time - start) / options.duration;
					if (timeFraction > 1) timeFraction = 1;
					// the start can actually get a negative value for some reason
					// so clamp it
					if (timeFraction < 0) timeFraction = 0;

					// calculate the current animation state
					let progress = options.timing ? options.timing(timeFraction) : timeFraction;

					options.draw(progress); // draw it

					if (timeFraction < 1) {
						animationFrameRequest = requestAnimationFrame(animate);
					} else if (options.next) {
						startAnimation(options.next);
					}
				});
			}

			let diagram = new RampslideDiagram(
				document.getElementById('clipvelocity-enter-example'),
				{angle: 30, magnitude: 700, offset: 200, alwaysParallel: true}
			);
			let enterAngle = 45;
			let enterMagnitude = 700;
			let afterVelRect = diagram.velocityArrowContainer.getBoundingClientRect();
			let containerRect = diagram.root.getBoundingClientRect();
			let enterAnchorRelative = new Vec2d(
				afterVelRect.right - containerRect.left,
				afterVelRect.bottom - containerRect.top
			);
			let beforeVelArrowContainer = diagram.root.querySelector('.velocity-arrow-enter-container');
			let clipVelocityStatus = diagram.root.querySelector('.status-clipvelocity');

			let updateEnterAngle = function(newAngle) {
				enterAngle = newAngle;
				let enterVelocity = getVector(diagram.angle-enterAngle, enterMagnitude);
				let clippedVec = clipVelocity(enterVelocity, diagram.getSurfaceNormal());
				diagram.magnitude = clippedVec.length();
			};

			updateEnterAngle(enterAngle);

			diagram.onupdate = function() {
				beforeVelArrowContainer.style.left=enterAnchorRelative.x + 'px';
				beforeVelArrowContainer.style.top=enterAnchorRelative.y + 'px';
				beforeVelArrowContainer.style.transform = 'rotate('+(diagram.angle-enterAngle)+'deg) translate(0, -3px)';

				clipVelocityStatus.innerHTML = "velocity maintained during ClipVelocity: " + Math.round(diagram.magnitude / enterMagnitude * 100) + "%";
			};

			let start = { duration: 2000,
				draw: function(progress) {
					updateEnterAngle(45 - 45 * progress);
					diagram.updateExcludeSlope();
				}
			};
			let up = { duration: 4000,
				draw: function(progress) {
					updateEnterAngle(85 * progress);
					diagram.updateExcludeSlope();
				}
			};
			let down = { duration: 4000,
				draw: function(progress) {
					updateEnterAngle(85 - 85 * progress);
					diagram.updateExcludeSlope();
				}
			};
			start.next = up;
			up.next = down;
			down.next = up;
			startAnimation(start);
		};

		let initDiagram3 = function() {
			let diagram = new RampslideDiagram(
				document.getElementById('clipvelocity-example'), 
				{angle: 30, magnitude: 700, offset: 50}
			);

			var curStep = 0;
			let stepsContainer = diagram.root.querySelector('.steps');
			let gravityInput = diagram.root.querySelector('.gravity-controls input');
			var steps = [
				{
					element: stepsContainer.querySelector('.clip-velocity'),
					fn: function() {
						diagram.velocity = clipVelocity(diagram.velocity, diagram.getSurfaceNormal());
						diagram.updateExcludeSlope();
					}
				},
				{
					element: stepsContainer.querySelector('.move'),
					fn: function() {
						diagram.offset += diagram.velocity.length() / 75;
						diagram.updateExcludeSlope();
					}
				},
				{
					element: stepsContainer.querySelector('.gravity'),
					fn: function() {
						diagram.velocity.y -= parseInt(gravityInput.value);
						diagram.updateExcludeSlope();
					}
				}
			];
			setInterval(function() {
				if (Math.round(diagram.offset) >= 200 || Math.round(diagram.velocity.y) <= 180) {
					steps[curStep].element.classList.remove('current');
					diagram.velocity = diagram.getVelocity(700);
					diagram.offset = 50;
					diagram.update();
					curStep = 0;
					steps[curStep].element.classList.add('current');
					return;
				}

				steps[curStep].element.classList.remove('current');
				curStep = (curStep+1) % steps.length;
				steps[curStep].element.classList.add('current');
				steps[curStep].fn();
			}, 1000);
		};

		let initDiagram4 = function() {
			let diagram = new RampslideDiagram(
				document.getElementById('clipvelocity-addendum-1'), 
				{angle: 30, magnitude: 700, offset: 50, alwaysParallel: true, scale: 6}
			);

			{
				let enterAngle = 60;
				let enterMagnitude = 700;
				let beforeVelArrowContainer = diagram.root.querySelector('.velocity-arrow-enter-container');
				let beforeVelArrow = beforeVelArrowContainer.querySelector('.velocity-arrow');

				diagram.updateEnterAngle = function(newAngle) {
					enterAngle = newAngle;
					let enterVelocity = getVector(diagram.angle-enterAngle, enterMagnitude);
					let clippedVec = clipVelocity(enterVelocity, diagram.getSurfaceNormal());
					diagram.magnitude = clippedVec.length();
				};

				diagram.updateEnterAngle(enterAngle);

				diagram.onupdate = function() {
					beforeVelArrow.style.width = (enterMagnitude / diagram.scale) + 'px';
					let afterVelRect = diagram.velocityArrowContainer.getBoundingClientRect();
					let containerRect = diagram.root.getBoundingClientRect();
					let enterAnchorRelative = new Vec2d(
						afterVelRect.right - containerRect.left,
						afterVelRect.bottom - containerRect.top
					);
					beforeVelArrowContainer.style.left=enterAnchorRelative.x + 'px';
					beforeVelArrowContainer.style.top=enterAnchorRelative.y + 'px';
					beforeVelArrowContainer.style.transform = 'rotate('+(diagram.angle-enterAngle)+'deg) translate(0, -3px)';
				};
			}

			let diagram2 = new RampslideDiagram(
				document.getElementById('clipvelocity-addendum-2'), 
				{angle: 30, magnitude: 700, offset: 0, alwaysParallel: true, scale: 6}
			);

			{
				let enterAngle = 60;
				let enterMagnitude = 700;
				let interVelArrowContainer = diagram2.root.querySelector('.velocity-arrow-intermediate-container');
				let interVelArrow = interVelArrowContainer.querySelector('.velocity-arrow');
				let interVelArrowMagnitude = interVelArrowContainer.querySelector('.velocity-magnitude');
				let beforeVelArrowContainer = diagram2.root.querySelector('.velocity-arrow-enter-container');
				let beforeVelArrow = beforeVelArrowContainer.querySelector('.velocity-arrow');
				let status = diagram2.root.querySelector('.status-clipvelocity');

				diagram2.updateEnterAngle = function(newAngle) {
					enterAngle = newAngle;
					let enterVelocity = getVector(diagram2.angle-enterAngle, enterMagnitude);
					diagram2.intermediateVelocity = clipVelocity(enterVelocity, new Vec2d(0, 1));
					diagram2.velocity = clipVelocity(diagram2.intermediateVelocity, diagram2.getSurfaceNormal());
					diagram2.magnitude = diagram2.velocity.length();
				};

				diagram2.updateEnterAngle(enterAngle);

				diagram2.onupdate = function() {
					beforeVelArrow.style.width = (enterMagnitude / diagram2.scale) + 'px';
					interVelArrow.style.width = (diagram2.intermediateVelocity.length() / diagram2.scale) + 'px';
					interVelArrowMagnitude.innerHTML = Math.round(diagram2.intermediateVelocity.length());
					let afterVelRect = interVelArrow.getBoundingClientRect();
					let containerRect = diagram2.root.getBoundingClientRect();
					let enterAnchorRelative = new Vec2d(
						afterVelRect.right - containerRect.left,
						afterVelRect.bottom - containerRect.top
					);
					beforeVelArrowContainer.style.left=enterAnchorRelative.x + 'px';
					beforeVelArrowContainer.style.top=enterAnchorRelative.y + 'px';
					beforeVelArrowContainer.style.transform = 'rotate('+(diagram2.angle-enterAngle)+'deg) translate(0, -3px)';
					let percentIncrease = (diagram2.velocity.length() - diagram.magnitude) / diagram.magnitude * 100;
					status.innerHTML = 'increased % velocity maintained from landing on flat: ' + Math.round(percentIncrease) + '%';
				};
			}

			let animationFrameRequest;
			function startAnimation(options) {
				let start = performance.now();

				animationFrameRequest = requestAnimationFrame(function animate(time) {
					// timeFraction goes from 0 to 1
					let timeFraction = (time - start) / options.duration;
					if (timeFraction > 1) timeFraction = 1;
					// the start can actually get a negative value for some reason
					// so clamp it
					if (timeFraction < 0) timeFraction = 0;

					// calculate the current animation state
					let progress = options.timing ? options.timing(timeFraction) : timeFraction;

					options.draw(progress); // draw it

					if (timeFraction < 1) {
						animationFrameRequest = requestAnimationFrame(animate);
					} else if (options.next) {
						startAnimation(options.next);
					}
				});
			}
			let start = { duration: 2000,
				draw: function(progress) {
					diagram.updateEnterAngle(60 - 20 * progress);
					diagram2.updateEnterAngle(60 - 20 * progress);
					diagram.updateExcludeSlope();
					diagram2.updateExcludeSlope();
				}
			};
			let up = { duration: 4000,
				draw: function(progress) {
					diagram.updateEnterAngle(40 + 40 * progress);
					diagram2.updateEnterAngle(40 + 40 * progress);
					diagram.updateExcludeSlope();
					diagram2.updateExcludeSlope();
				}
			};
			let down = { duration: 4000,
				draw: function(progress) {
					diagram.updateEnterAngle(80 - 40 * progress);
					diagram2.updateEnterAngle(80 - 40 * progress);
					diagram.updateExcludeSlope();
					diagram2.updateExcludeSlope();
				}
			};
			start.next = up;
			up.next = down;
			down.next = up;
			startAnimation(start);
		};

		let ready = function() {
			initDiagram1();
			initDiagram2();
			initDiagram3();
			initDiagram4();
		};
		if (document.readyState == 'complete' || document.readyState == 'loaded') {
			ready();
		} else {
			window.addEventListener('DOMContentLoaded', ready);
		}
	})();
</script>

<div>
	<style scoped>
		.rampsliding-diagram {
			margin-right: auto; margin-left: auto; display: block;
			width: 500px; height: 400px;
			position: relative;
			background-color: #eee;
			overflow: hidden;
		}
		@media (prefers-color-scheme: dark) {
		.rampsliding-diagram {
			background-color: #111;
		}
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
		@media (prefers-color-scheme: dark) {
		.rampsliding-diagram .slope {
			background-color: #ddd;
		}
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
		@media (prefers-color-scheme: dark) {
		.rampsliding-diagram .slope-angle-circle > div {
			border-color: rgba(255,255,255,0.5);
		}
		}
		.rampsliding-diagram .ground {
			position: absolute;
			bottom: 30px;
			right: 50px;
			width: 400px;
			height: 1px;
			background-color: rgba(0,0,0,0.5);
		}
		@media (prefers-color-scheme: dark) {
		.rampsliding-diagram .ground {
			background-color: rgba(255,255,255,0.5);
		}
		}
		#clipvelocity-addendum-1.rampsliding-diagram,
		#clipvelocity-addendum-2.rampsliding-diagram {
			height: 175px;
		}
		#clipvelocity-addendum-1.rampsliding-diagram .flat,
		#clipvelocity-addendum-2.rampsliding-diagram .flat {
			position: absolute;
			bottom: 30px;
			right: 50px;
			width: 200px;
			height: 5px;
			background-color: black;
		}
		@media (prefers-color-scheme: dark) {
		#clipvelocity-addendum-1.rampsliding-diagram .flat,
		#clipvelocity-addendum-2.rampsliding-diagram .flat {
			background-color: #ddd;
		}
		}
		#clipvelocity-addendum-1.rampsliding-diagram .slope,
		#clipvelocity-addendum-2.rampsliding-diagram .slope {
			right: 250px;
			width: 200px;
		}
		#clipvelocity-addendum-1.rampsliding-diagram .slope-angle-circle,
		#clipvelocity-addendum-2.rampsliding-diagram .slope-angle-circle {
			right: 250px;
			width: 200px;
			height: 200px;
		}
		#clipvelocity-addendum-1.rampsliding-diagram .slope-angle-circle > div,
		#clipvelocity-addendum-2.rampsliding-diagram .slope-angle-circle > div {
			width: 199px;
			height: 199px;
		}
		#clipvelocity-addendum-1.rampsliding-diagram .velocity-arrow-container,
		#clipvelocity-addendum-2.rampsliding-diagram .velocity-arrow-container {
			right: 250px;
		}
		#clipvelocity-addendum-1 .velocity-arrow-container {
			transform: rotate(30deg) translate(-50px, -20px);
		}
		#clipvelocity-addendum-1 .velocity-arrow-container .velocity-arrow {
			width: 58.3333px;
		}
		#clipvelocity-addendum-1 .velocity-arrow-enter-container {
			left: 216.7px; top: 102.683px; transform: rotate(-30deg) translate(0px, -3px);
		}
		#clipvelocity-addendum-1 .velocity-arrow-enter-container .velocity-arrow {
			width: 116.667px;
		}

		#clipvelocity-addendum-2 .velocity-arrow-container {
			transform: rotate(30deg) translate(0px, -20px);
		}
		#clipvelocity-addendum-2 .velocity-arrow-container .velocity-arrow {
			width: 87.5px;
		}
		#clipvelocity-addendum-2 .velocity-arrow-enter-container {
			left: 361.033px; top: 128px; transform: rotate(-30deg) translate(0px, -3px);
		}
		#clipvelocity-addendum-2 .velocity-arrow-enter-container .velocity-arrow {
			width: 116.667px;
		}
		.rampsliding-diagram .velocity-arrow {
			position: absolute;
			bottom: 0px;
			right: 0px;
			width: 200px;
			height: 3px;
			transform-origin: 100% 100%;
			transform: none;
			background-color: black;
			z-index: 5;
		}
		@media (prefers-color-scheme: dark) {
		.rampsliding-diagram .velocity-arrow {
			background-color: #ddd;
		}
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
		@media (prefers-color-scheme: dark) {
		.rampsliding-diagram .velocity-arrow::after { 
			border-right-color: #ddd;
		}
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
		#velocity-example.rampsliding-diagram .velocity-magnitude {
			cursor: nwse-resize;
			-webkit-touch-callout: none;  
			-webkit-user-select: none;
			-khtml-user-select: none;
			-moz-user-select: none;
			-ms-user-select: none;
			user-select: none;
		}
		.rampsliding-diagram .velocity-components {
			position: absolute;
			border-right: 1px dashed;
			border-top: 1px dashed;
			border-color: rgba(0,0,0,.5);
			z-index: 4;
		}
		@media (prefers-color-scheme: dark) {
		.rampsliding-diagram .velocity-components {
			border-color: rgba(255,255,255,.5);
		}
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
		.rampsliding-diagram .status, .rampsliding-diagram .status-clipvelocity {
			position:absolute;
			left: 0px; right: 0px; top: 1em;
			text-align: center;
		}
		.rampsliding-diagram .steps {
			position: absolute;
			right: 0; top: 0;
		}
		.rampsliding-diagram .velocity-arrow-container {
			position: absolute;
			bottom: 30px;
			right: 50px;
			width: 200px;
			transform-origin: 100% 100%;
			transform: rotate(30deg) translate(-50px, -20px);
			z-index: 5;
		}
		#velocity-example.rampsliding-diagram .velocity-arrow-container {
			transform: rotate(30deg) translate(-100px, -20px);
		}
		#velocity-example.rampsliding-diagram .velocity-components {
			left: 200.2px; bottom: 97.3167px;
			width: 174.7px; height: 102.6px;
		}
		#clipvelocity-example.rampsliding-diagram .velocity-components {
			left: 243.5px; bottom: 72.3167px;
			width: 174.7px; height: 102.6px;
		}
		#clipvelocity-enter-example.rampsliding-diagram .velocity-arrow-container {
			transform: rotate(30deg) translate(-200px, -20px);
		}
		#clipvelocity-enter-example.rampsliding-diagram .velocity-components {
			left: 113.583px; bottom: 147.317px;
			width: 174.7px; height: 102.6px;
		}
		.rampsliding-diagram .steps {
			list-style: none;
			text-align: left;
			margin: 1em;
			padding: 0;
		}
		.rampsliding-diagram .steps li {
			background-color: rgba(0,0,0,.1);
			padding: .1em .5em;
			margin-bottom: .25em;
		}
		.rampsliding-diagram .steps li.current {
			background-color: rgba(0,255,0,.1);
		}
		.rampsliding-diagram .steps li.current::before {
			content: '>';
			right: 100%;
			margin-right: 3px;
			position: absolute;
			font-weight: bold;
		}
		.rampsliding-diagram .gravity-controls {
			text-align: left;
			margin: 1em;
		}
		.rampsliding-diagram .slope-angle-lock {
			position: absolute;
			text-align: center;
			line-height: 2em;
			width: 2em;
			height: 2em;
			background-color: #ddd;
			border-radius: 50%;
			line-height: 2em;
			width: 2em;
			height: 2em;
			z-index: 10;
			cursor: pointer;
			opacity: 0.66;
		}
		@media (prefers-color-scheme: dark) {
		.rampsliding-diagram .slope-angle-lock {
			background-color: #333;
		}
		}
		.rampsliding-diagram .slope-angle-lock:hover {
			opacity: 1;
		}
		.rampsliding-diagram .slope-angle-lock.unlocked::before {
			content: "\01F513";
		}
		.rampsliding-diagram .slope-angle-lock.unlocked:hover::before {
			content: "\01F512";
		}
		.rampsliding-diagram .slope-angle-lock.locked::before {
			content: "\01F512";
		}
		.rampsliding-diagram .slope-angle-lock.locked:hover::before {
			content: "\01F513";
		}
		.caption {
			background-color: rgba(0,0,0, .1);
			margin:0; padding: .25em;
			width: auto;
			max-width: 75%; display: inline-block;
			margin-left: auto; margin-right: auto;
		}
		#clipvelocity-enter-example .velocity-arrow-container .velocity-arrow {
			width: 141.421px;
		}
		#clipvelocity-enter-example .velocity-arrow-container .velocity-arrow,
		#clipvelocity-addendum-1 .velocity-arrow-container .velocity-arrow,
		#clipvelocity-addendum-2 .velocity-arrow-container .velocity-arrow {
			background-color: #5A06CC;
		}
		#clipvelocity-enter-example .velocity-arrow-container .velocity-arrow::after,
		#clipvelocity-addendum-1 .velocity-arrow-container .velocity-arrow::after,
		#clipvelocity-addendum-2 .velocity-arrow-container .velocity-arrow::after {
			border-right-color: #5A06CC;
		}
		#clipvelocity-addendum-2 .status-clipvelocity {
			top: 0px;
		}
		.rampsliding-diagram .velocity-arrow-enter-container {
			position: absolute;
			width: 200px;
			transform-origin: 0 0;
			transform: rotate(-15deg) translate(0, -3px);
			z-index: 5;
			left: 286.783px; top: 252.683px;
		}
		.rampsliding-diagram .velocity-arrow-enter-container .velocity-arrow {
			position: absolute;
			top: 0px;
			left: 0px;
			width: 200px;
			height: 3px;
			transform-origin: 0% 0%;
			transform: none;
			z-index: 5;
			background-color: #484848;
		}
		.rampsliding-diagram .velocity-arrow-enter-container .velocity-arrow::after {
			border-right-color: #484848;
		}
		@media (prefers-color-scheme: dark) {
		.rampsliding-diagram .velocity-arrow-enter-container .velocity-arrow {
			background-color: #81798B;
		}
		.rampsliding-diagram .velocity-arrow-enter-container .velocity-arrow::after {
			border-right-color: #81798B;
		}
		}
		.rampsliding-diagram .velocity-arrow-intermediate-container {
			position: absolute;
			width: 200px;
			z-index: 5;
			left: 260px; bottom: 50px;
		}
		.rampsliding-diagram .velocity-arrow-intermediate-container .velocity-arrow {
			position: absolute;
			top: 0px;
			left: 0px;
			width: 101.036px;
			height: 3px;
			z-index: 5;
			background-color: #645175;
		}
		.rampsliding-diagram .velocity-arrow-intermediate-container .velocity-arrow::after {
			border-right-color: #645175;
		}
	</style>
</div>