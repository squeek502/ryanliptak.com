The slope-related movement physics in the GoldSrc (Half-Life 1) engine and the Source (Half-Life 2) engine are fairly similar. However, there is one caveat around moving down slopes: in the GoldSrc engine you will bounce down slopes somewhat often, while in the Source engine you will smoothly move down almost any slope unless you collide with them while moving extremely quickly.

<div style="text-align: center;">
<video autoplay loop muted style="margin-left:auto; margin-right:auto; display: block;">
	<source src="/images/source-vs-goldsrc-movement-slopes/bounce.mp4" type="video/mp4">
</video>
<i class="caption">Bouncing off a ramp in Team Fortress Classic (GoldSrc)</i>
</div>

We'll get to some gameplay implications of this a bit later, but first let's establish the mechanics behind 'bouncing down a slope' because it's a bit weird.

## `ClipVelocity` making the velocity parallel to the slope

As [discussed in much more detail in the rampsliding post](/blog/rampsliding-quake-engine-quirk/), whenever a player collides with a surface, a function called `ClipVelocity` will transform their velocity to be parallel to that surface. One characteristic of this function that's worth noting is that the closer to parallel the velocity already is, the more speed will be maintained after the collision.

<div style="text-align: center;">
	<div id="clipvelocity-enter-example" class="rampsliding-diagram">
		<div class="slope"></div>
		<div class="ground"></div>
		<div class="slope-angle">30&deg;</div>
		<div class="slope-angle-circle"><div></div></div>
		<div class="velocity-arrow-container" style="transform: rotate(-30deg) translate(0px, -20px);">
			<div class="velocity-arrow" style="width: 134.058px;">
				<div class="velocity-magnitude">536</div>
			</div>
		</div>
		<div class="velocity-arrow-enter-container" style="left: 213.2px; top: 252.683px; transform: rotate(-70deg) translate(0px, -3px);">
			<div class="velocity-arrow">
				<div class="velocity-magnitude">700</div>
			</div>
		</div>
		<div class="status-clipvelocity">velocity maintained during ClipVelocity: 77%</div>
	</div>
	<i class="caption">Speed loss due to ClipVelocity at different approach angles</i>
</div>

But if `ClipVelocity` makes the velocity parallel to the surface, then where does the bounce come from? Well, that's where a quirk of the movement physics comes into play.

## Flattening velocity when on the ground

After `ClipVelocity` finishes and most of the rest of the movement code is run (the player actually moves a tiny amount along the slope using the result of `ClipVelocity`, etc), there are two things towards the end of the movement code that matter:

1. [`CatagorizePosition`](https://github.com/ValveSoftware/halflife/blob/c7240b965743a53a29491dd49320c88eecf6257b/pm_shared/pm_shared.c#L1542-L1593) [sic] is called and, in the case we care about here, [it will determine that we are now 'on the ground'](https://github.com/ValveSoftware/halflife/blob/c7240b965743a53a29491dd49320c88eecf6257b/pm_shared/pm_shared.c#L1575) (since we've just collided with a ramp that is not too-steep-to-stand-on).
2. Whenever a player is 'on the ground', [the vertical component of their velocity always gets set to zero](https://github.com/ValveSoftware/halflife/blob/c7240b965743a53a29491dd49320c88eecf6257b/pm_shared/pm_shared.c#L3181-L3185) (i.e. their velocity is made to be purely horizontal by just dropping all vertical speed).

This means that the resulting velocity *after* colliding with a shallow-enough downward slope is always perfectly horizontal, and that the player's final speed is determined solely by the horizontal components of the result of `ClipVelocity`.

<div style="text-align: center;">
	<div id="clipvelocity-bounce" class="rampsliding-diagram">
		<div class="slope"></div>
		<div class="ground"></div>
		<div class="slope-angle">30&deg;</div>
		<div class="slope-angle-circle"><div></div></div>
		<div class="velocity-arrow-container" style="transform: rotate(-30deg) translate(50px, -20px);">
			<div class="velocity-arrow" style="width: 153.209px;">
				<div class="velocity-magnitude">536</div>
			</div>
		</div>
		<div class="velocity-arrow-final-container" style="right: 243.5px; top: 227.683px;">
			<div class="velocity-arrow" style="width: 132.683px;">
				<div class="velocity-magnitude">464</div>
			</div>
		</div>
		<div class="velocity-arrow-enter-container" style="left: 256.5px; top: 227.683px; transform: rotate(-70deg) translate(0px, -3px);">
			<div class="velocity-arrow" style="width: 200px;">
				<div class="velocity-magnitude">700</div>
			</div>
		</div>
	</div>
	<i class="caption">The final velocity (in purple) after flattening the result of ClipVelocity (shown as dashed)</i>
</div>

Because velocity is now flat (rather than parallel to the surface we collided with), it's very likely that on one of the next few subsequent ticks, the player will move far enough off the slope that they will no longer be considered 'on the ground,' and thus will start falling again (e.g. they will bounce off the ramp).

## You're not leaving this slope that easily

If this were the whole story, then players would do nothing but bounce whenever they tried to move down a slope. To avoid bouncing when just trying to walk down a slope, there is [a small correction made whenever a player is 'on the ground' but slightly above a surface](https://github.com/ValveSoftware/halflife/blob/c7240b965743a53a29491dd49320c88eecf6257b/pm_shared/pm_shared.c#L1577-L1585):

- After determining that a player is 'on the ground', it will look 2 units directly below the player and check if there's a surface there that is shallow enough to stand on.
- If there is, it will simply snap the player down onto that surface (without changing their velocity).

This means that it is slightly harder to 'escape' a slope once the movement code has determined you are 'on the ground.' If you try running down a slope, your velocity *will* be flat the whole way (zero vertical component), but you will be snapped back to the surface of the slope each tick as long as you are moving slowly enough. So, the only way to actually bounce down a slope is to horizontally move far enough in one tick that the slope is more than 2 units below your new position (i.e. you have to still be going fairly fast horizontally *after* colliding with the slope in order to bounce off of it).

<div style="text-align: center;">
	<div id="clipvelocity-stayonground-goldsrc" class="rampsliding-diagram bouncing">
		<div class="slope"></div>
		<div class="ground"></div>
		<div class="slope-angle">30&deg;</div>
		<div class="slope-angle-circle"><div></div></div>
		<div class="velocity-arrow-container" style="transform: rotate(-30deg) translate(50px, -20px);">
			<div class="velocity-arrow" style="width: 80px; transform: rotate(30deg);">
				<div class="velocity-magnitude">4</div>
			</div>
		</div>
		<div class="stepsize-components" style="left: 176.5px; top: 124.683px; width: 80px; height: 66.188px;">
			<div class="height">2.3</div>
		</div>
		<div class="status">result: bouncing off the slope</div>
	</div>
	<i class="caption">Diagram showing the necessary horizontal distance traveled in one tick to bounce off a 30&deg; slope in the GoldSrc engine</i>
</div>

## What the Source engine does differently

Everything above is the same in the Source engine, however, the miniature 'snap the player onto the ramp if they're close enough to it' functionality was substantially upgraded: instead of just checking 2 units below the player, it now checks for slopes up to 18 units below the player (technically, the distance it checks is determined by `StepSize`, but `StepSize` is typically set to 18). This is done during a new function called [`StayOnGround`](https://github.com/ValveSoftware/source-sdk-2013/blob/0d8dceea4310fde5706b3ce1c70609d72a38efdf/sp/src/game/shared/gamemovement.cpp#L1856-L1890) which is run during `WalkMove` (which is only called when the player is on the ground).

<aside class="note"><p>Note: `StepSize` is the height that you are allowed to step up if you hit an obstacle (to allow for walking up stairs). It is controlled by `sv_stepsize` and is defaulted to `18` in both the Source and GoldSrc engines.</p></aside>

<div style="text-align: center;">
	<div id="clipvelocity-stayonground-source" class="rampsliding-diagram bouncing">
		<div class="slope"></div>
		<div class="ground"></div>
		<div class="slope-angle">30&deg;</div>
		<div class="slope-angle-circle"><div></div></div>
		<div class="velocity-arrow-container" style="transform: rotate(-30deg) translate(50px, -20px);">
			<div class="velocity-arrow" style="width: 113.333px; transform: rotate(30deg);">
				<div class="velocity-magnitude">34</div>
			</div>
		</div>
		<div class="stepsize-components" style="left: 143.167px; top: 124.683px; width: 113.333px; height: 85.433px;">
			<div class="height">20</div>
		</div>
		<div class="status">result: bouncing off the slope</div>
		<div class="stepsize-value"><code>StepSize = 18</code></div>
	</div>
	<i class="caption">Diagram showing the necessary horizontal distance traveled in one tick to bounce off a 30&deg; slope in the Source engine</i>
</div>

## What a movement 'tick' means in each engine

We've now established that being able to bounce off a slope is limited/dictated by the distance traveled in a single tick. If ticks occur very slowly, then each tick will involve a longer distance traveled than if ticks happen very quickly. For example, if a player is moving 1000 units/sec and the movement is processed at 1 tick/sec, then the player will move 1000 units each tick; however, if the movement is processed at 100 ticks/sec, then the player will move 10 units per tick.

So, what determines how long each 'tick' is? Well, this differs per engine:

- In the GoldSrc engine, movement physics are run on each *client frame*, meaning the client's frames per second determine how long each movement tick is, and therefore how much or little movement happens per tick. This means that setting `fps_max` to something like `10` will make you bounce down almost any slope at almost any speed, but setting `fps_max` to `300` will make you smoothly run down almost any slope and you will only bounce when colliding with a downward slope at high speeds.
- In the Source engine, how often movement physics are run is dictated by the `-tickrate` of the server (the client's FPS has no effect). This means that each player in a given server will have consistent movement physics, but also that different *servers* may have different movement physics depending on their `-tickrate` setting. Note, though, that it's fairly common for games on the Source engine to have a standard/enforced/recommended `-tickrate`.

<aside class="note"><p>Note: I'm not fully confident in my understanding of this tick/frame-related stuff, so don't take it as gospel. The part about FPS mattering in GoldSrc but not mattering in Source is true and can be (and was) verified experimentally, but my understanding of how everything (client frames, server networking, etc.) fits together is lacking so I may not be presenting the full picture.</p></aside>

## Gameplay ramifications in Fortress games

In the games [Team Fortress Classic](https://en.wikipedia.org/wiki/Team_Fortress_Classic) (GoldSrc engine) and [Fortress Forever](https://www.fortress-forever.com/) (Source engine), bouncing down ramps can be used to a player's advantage. In both games, concussion grenades allow you to intentionally hit downward ramps at high speeds and the ability to preserve that momentum via bouncing off the ramp is extremely advantageous (versus hitting the ramp and slowing down to either runspeed or the bunnyhop cap).

<div style="text-align: center; width: 80%; margin-left: auto; margin-right: auto;">
<video controls muted style="margin-left:auto; margin-right:auto; display: block; width: 50%; float: left;">
	<source src="/images/source-vs-goldsrc-movement-slopes/tfc.mp4" type="video/mp4">
</video>
<video controls muted style="margin-left:auto; margin-right:auto; display: block; width: 50%; float: right;">
	<source src="/images/source-vs-goldsrc-movement-slopes/ff.mp4" type="video/mp4">
</video>
<i class="caption">Similar techniques that exploit bouncing off a ramp at high speeds in Team Fortress Classic (GoldSrc engine) [left] and Fortress Forever (Source engine) [right]</i>
</div>

<aside class="note"><p>Note: In both of the above clips, a hand-held concussion grenade is used right before hitting the ramp which generates most of the speed that then gets transferred into the bounce.</p></aside>

Due to the differences between the engines discussed previously, the bounce in the Team Fortress Classic clip would not have worked in Fortress Forever. The bounce in the Fortress Forever clip in this case uses two additional helping hands:

- Two concussion grenades combo'd together (the speed generated by concussion grenades is multiplicative), and
- An approach angle that is more parallel to the surface of the ramp that is being collided with

We'll get into the details of what will and won't generate a bounce in Fortress Forever specifically, but first let's explore which factors matter for how fast the bounce ends up being.

### Understanding how to maximize the bounce speed

There are two main factors that determine the final speed after a bounce (besides the entry speed):

1. **The angle of approach:** Hitting the ramp while moving close to parallel to its surface means more velocity maintained during `ClipVelocity`
2. **The angle of the ramp:** The shallower the ramp itself, the less velocity is lost when it is 'flattened' (e.g. the more horizontal the velocity is after `ClipVelocity`, the less vertical velocity there is to lose when it's flattened)

So, in theory, the fastest bounce would be achieved by hitting a very shallow ramp while moving very close to parallel to its surface. In practice, this is made extremely difficult for two different reasons:

1. Steeper ramps are easier to collide with at more-parallel approach angles. It's not easy to collide with a near-horizontal downwards ramp while moving nearly horizontally yourself.
2. The shallower the ramp, the faster you have to be going to be able to bounce at all. To bounce, you need to move far enough in one tick that the ramp becomes far enough below you that you don't get snapped back down onto its surface. The shallower the ramp, the further you'd need to travel to clear that threshold.

<div style="text-align: center;">
	<div id="diagram-bounce-speed" class="rampsliding-diagram">
		<div class="slope"></div>
		<div class="ground"></div>
		<div class="slope-angle">30&deg;</div>
		<div class="slope-angle-circle"><div></div></div>
		<div class="velocity-arrow-container" style="transform: rotate(-30deg) translate(0px, -20px);">
			<div class="velocity-arrow" style="width: 153.209px;">
				<div class="velocity-magnitude">536</div>
			</div>
		</div>
		<div class="velocity-arrow-final-container" style="right: 286.8px; top: 327.683px;">
			<div class="velocity-arrow" style="width: 132.683px;">
				<div class="velocity-magnitude">464</div>
			</div>
		</div>
		<div class="velocity-arrow-enter-container" style="left: 213.2px; top: 327.683px; transform: rotate(-70deg) translate(0px, -3px);">
			<div class="velocity-arrow">
				<div class="velocity-magnitude">700</div>
			</div>
		</div>
		<div class="status status-speed">
			<div class="maintained">velocity maintained after bounce: 66%</div>
			<div class="loss-contributors">
				<div class="contributor-clipvelocity">23% decrease during ClipVelocity</div>
				<div class="contributor-flattening">13% decrease during velocity flattening</div>
			</div>
		</div>
	</div>
	<i class="caption">Speed maintained through a bounce at various approach and slope angles</i>
</div>

### The speed needed to bounce in Fortress Forever

Fortress Forever has a default of `-tickrate 66` (and this is what most/all servers use), so we can use that to determine specifically what speeds are necessary to achieve a bounce for a given approach and slope angle combination.

<aside class="note"><p>Note: The speedometer on the Fortress Forever HUD only shows horizontal speed, not 3D speed, but it's your 3D speed that matters for bouncing off a slope.</p></aside>

<div style="text-align: center;">
	<div id="clipvelocity-fortressforever" class="rampsliding-diagram bouncing">
		<div class="slope"></div>
		<div class="ground"></div>
		<div class="slope-angle">30&deg;</div>
		<div class="slope-angle-circle"><div></div></div>
		<div class="velocity-arrow-container" style="visibility: hidden;">
			<div class="velocity-arrow">
				<div class="velocity-magnitude">31</div>
			</div>
		</div>
		<div class="velocity-arrow-final-container" style="right: 286.8px; top: 252.683px;">
			<div class="velocity-arrow">
				<div class="velocity-magnitude">≥ 2058</div>
			</div>
		</div>
		<div class="velocity-arrow-enter-container" style="left: 213.2px; top: 252.683px; transform: rotate(-45deg) translate(0px, -3px);">
			<div class="velocity-arrow">
				<div class="velocity-magnitude">≥ 2460</div>
			</div>
		</div>
		<div class="controls">
		  <input title="slope angle" type="range" min="5" max="45" value="30" class="controls-slope-angle">
		  <input title="velocity angle" type="range" min="5" max="90" value="15" class="controls-velocity-angle">
		</div>
	</div>
	<i class="caption">Speed necessary to bounce off a slope in Fortress Forever (<code>-tickrate 66</code>)</i>
</div>

If you play around with the above diagram, you'll quickly notice that the speed threshold for bouncing off any ramp is quite high. In practice, you'll likely need to double concussion jump down into a ramp in order to get the speed necessary achieve a bounce at all.

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
				this.slopeAngle.innerHTML = Math.abs(Math.round(this.angle)) + "&deg;"; 
				let circleAngle = 90 + this.angle;
				this.slopeAngleCircle.style.transform = 'rotate(' + circleAngle + 'deg)';
			}

			updateVelocity() {
				this.velocityArrowContainer.style.transform = 'rotate(' + this.angle + 'deg) translate('+Math.round(this.offset)+'px, -20px)';
				this.velocityArrow.style.width = (this.magnitude / this.scale) + 'px';
				this.velocityArrow.style.transform = 'rotate(' + (this.velocityAngle-this.angle) + 'deg)';
				this.velocityMagnitude.textContent = Math.round(this.magnitude);
			}

			updateStatus() {
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
		let getNormal = function(angle) {
			let radians = angle / 180 * Math.PI;
			let x = Math.sin(radians);
			let y = Math.cos(radians);
			return new Vec2d(x, y).normalize();
		};

		let initClipVelocityDiagram = function() {
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
				{angle: -30, magnitude: 700, offset: 0, alwaysParallel: true, scale: 4}
			);
			let enterAngle = 40;
			let enterMagnitude = 700;
			let afterVelRect = diagram.velocityArrowContainer.getBoundingClientRect();
			let containerRect = diagram.root.getBoundingClientRect();
			let enterAnchorRelative = new Vec2d(
				afterVelRect.right - containerRect.left,
				afterVelRect.top - containerRect.top
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

				clipVelocityStatus.textContent = "velocity maintained during ClipVelocity: " + Math.round(diagram.magnitude / enterMagnitude * 100) + "%";
			};

			let start = { duration: 2000,
				draw: function(progress) {
					updateEnterAngle(40 - 20 * progress);
					diagram.updateExcludeSlope();
				}
			};
			let up = { duration: 4000,
				draw: function(progress) {
					updateEnterAngle(20 + 40 * progress);
					diagram.updateExcludeSlope();
				}
			};
			let down = { duration: 4000,
				draw: function(progress) {
					updateEnterAngle(60 - 40 * progress);
					diagram.updateExcludeSlope();
				}
			};
			start.next = up;
			up.next = down;
			down.next = up;
			startAnimation(start);
		};

		let initStayOnGroundDiagram = function(diagramOptions) {
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
				document.getElementById('clipvelocity-stayonground-'+diagramOptions.suffix),
				{angle: -30, magnitude: diagramOptions.magnitude, offset: 50, alwaysParallel: false, scale: diagramOptions.scale}
			);
			let stepsizeComponents = diagram.root.querySelector('.stepsize-components');
			let heightComponent = diagram.root.querySelector('.stepsize-components .height');

			diagram.onupdate = function() {
				let containerBounds = this.root.getBoundingClientRect();
				let arrowBounds = this.velocityArrow.getBoundingClientRect();
				stepsizeComponents.style.left = (arrowBounds.left-containerBounds.left)+'px';
				stepsizeComponents.style.top = Math.abs(arrowBounds.top-containerBounds.top)+'px';
				let arrowWidth = arrowBounds.right-arrowBounds.left;
				stepsizeComponents.style.width = (arrowWidth)+'px';
				let radians = this.angle / 180 * Math.PI;
				let pxAboveRamp = Math.abs(arrowWidth * Math.tan(radians));
				// to make the line hit the ramp, since the arrow starts above the ramp
				let arrowAboveRampPx = 20;
				stepsizeComponents.style.height = (pxAboveRamp+arrowAboveRampPx)+'px';
				// scaled arbitrarily to get values in the appropriate range
				let heightDist = Math.abs(this.magnitude * Math.tan(radians));
				heightComponent.textContent = diagramOptions.decimal ? heightDist.toFixed(1) : Math.ceil(heightDist);

				let prevBouncing = this.bouncing;
				this.bouncing = heightDist > diagramOptions.threshold;
				if (this.bouncing !== prevBouncing) {
					if (this.bouncing) {
						this.root.classList.add('bouncing');
						if (this.status) {
							this.status.textContent = "result: bouncing off the slope";
						}
					} else {
						this.root.classList.remove('bouncing');
						if (this.status) {
							this.status.textContent = "result: snapping to slope's surface";
						}
					}
				}
			};

			let range = diagramOptions.max - diagramOptions.min;
			let start = { duration: 2000,
				draw: function(progress) {
					diagram.velocity = getVector(0, diagramOptions.magnitude - (diagramOptions.magnitude - diagramOptions.min) * progress);
					diagram.updateExcludeSlope();
				}
			};
			let up = { duration: 4000,
				draw: function(progress) {
					diagram.velocity = getVector(0, diagramOptions.min + range * progress);
					diagram.updateExcludeSlope();
				}
			};
			let down = { duration: 4000,
				draw: function(progress) {
					diagram.velocity = getVector(0, diagramOptions.max - range * progress);
					diagram.updateExcludeSlope();
				}
			};
			start.next = up;
			up.next = down;
			down.next = up;
			startAnimation(start);
		};

		let initFlatteningDiagram = function() {
			let diagram = new RampslideDiagram(
				document.getElementById('clipvelocity-bounce'), 
				{angle: -30, magnitude: 700, offset: 50, alwaysParallel: true, scale: 3.5}
			);

			{
				let enterAngle = 40;
				let enterMagnitude = 700;
				let finalMagnitude = 100; // TODO
				let finalVelArrowContainer = diagram.root.querySelector('.velocity-arrow-final-container');
				let finalVelArrow = finalVelArrowContainer.querySelector('.velocity-arrow');
				let finalVelMagnitude = finalVelArrowContainer.querySelector('.velocity-magnitude');
				let beforeVelArrowContainer = diagram.root.querySelector('.velocity-arrow-enter-container');
				let beforeVelArrow = beforeVelArrowContainer.querySelector('.velocity-arrow');

				diagram.updateEnterAngle = function(newAngle) {
					enterAngle = newAngle;
					let enterVelocity = getVector(diagram.angle-enterAngle, enterMagnitude);
					let clippedVec = clipVelocity(enterVelocity, diagram.getSurfaceNormal());
					diagram.magnitude = clippedVec.length();
					finalMagnitude = Math.abs(clippedVec.x);
				};

				diagram.updateEnterAngle(enterAngle);

				diagram.onupdate = function() {
					beforeVelArrow.style.width = (enterMagnitude / diagram.scale) + 'px';
					let afterVelRect = diagram.velocityArrowContainer.getBoundingClientRect();
					let containerRect = diagram.root.getBoundingClientRect();
					let enterAnchorRelative = new Vec2d(
						afterVelRect.right - containerRect.left,
						afterVelRect.top - containerRect.top
					);
					beforeVelArrowContainer.style.left=enterAnchorRelative.x + 'px';
					beforeVelArrowContainer.style.top=enterAnchorRelative.y + 'px';
					beforeVelArrowContainer.style.transform = 'rotate('+(diagram.angle-enterAngle)+'deg) translate(0, -3px)';
					finalVelArrow.style.width = (finalMagnitude / diagram.scale) + 'px';
					finalVelArrowContainer.style.right=(containerRect.right - afterVelRect.right) + 'px';
					finalVelArrowContainer.style.top=enterAnchorRelative.y + 'px';
					finalVelMagnitude.textContent = Math.round(finalMagnitude);
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
					diagram.updateEnterAngle(40 - 20 * progress);
					diagram.updateExcludeSlope();
				}
			};
			let up = { duration: 4000,
				draw: function(progress) {
					diagram.updateEnterAngle(20 + 40 * progress);
					diagram.updateExcludeSlope();
				}
			};
			let down = { duration: 4000,
				draw: function(progress) {
					diagram.updateEnterAngle(60 - 40 * progress);
					diagram.updateExcludeSlope();
				}
			};
			start.next = up;
			up.next = down;
			down.next = up;
			startAnimation(start);
		};

		let initBounceSpeedDiagram = function() {
			let diagram = new RampslideDiagram(
				document.getElementById('diagram-bounce-speed'), 
				{angle: -30, magnitude: 700, offset: 0, alwaysParallel: true, scale: 3.5}
			);

			{
				let enterAngle = 60;
				let enterMagnitude = 700;
				let finalMagnitude = 100; // TODO
				let finalVelArrowContainer = diagram.root.querySelector('.velocity-arrow-final-container');
				let finalVelArrow = finalVelArrowContainer.querySelector('.velocity-arrow');
				let finalVelMagnitude = finalVelArrowContainer.querySelector('.velocity-magnitude');
				let beforeVelArrowContainer = diagram.root.querySelector('.velocity-arrow-enter-container');
				let beforeVelArrow = beforeVelArrowContainer.querySelector('.velocity-arrow');
				let statusSpeed = diagram.root.querySelector('.status-speed');
				let statusMaintained = statusSpeed.querySelector('.maintained');
				let statusContributors = statusSpeed.querySelector('.loss-contributors');
				let statusContributorClipVelocity = statusContributors.querySelector('.contributor-clipvelocity');
				let statusContributorFlattening = statusContributors.querySelector('.contributor-flattening');

				diagram.updateEnterAngle = function(newAngle) {
					enterAngle = newAngle;
					let enterVelocity = getVector(diagram.angle-enterAngle, enterMagnitude);
					let clippedVec = clipVelocity(enterVelocity, diagram.getSurfaceNormal());
					diagram.magnitude = clippedVec.length();
					finalMagnitude = Math.abs(clippedVec.x);
				};

				diagram.updateEnterAngle(enterAngle);

				diagram.onupdate = function() {
					beforeVelArrow.style.width = (enterMagnitude / diagram.scale) + 'px';
					let afterVelRect = diagram.velocityArrowContainer.getBoundingClientRect();
					let containerRect = diagram.root.getBoundingClientRect();
					let enterAnchorRelative = new Vec2d(
						afterVelRect.right - containerRect.left,
						afterVelRect.top - containerRect.top
					);
					beforeVelArrowContainer.style.left=enterAnchorRelative.x + 'px';
					beforeVelArrowContainer.style.top=enterAnchorRelative.y + 'px';
					beforeVelArrowContainer.style.transform = 'rotate('+(diagram.angle-enterAngle)+'deg) translate(0, -3px)';
					finalVelArrow.style.width = (finalMagnitude / diagram.scale) + 'px';
					finalVelArrowContainer.style.right=(containerRect.right - afterVelRect.right) + 'px';
					finalVelArrowContainer.style.top=enterAnchorRelative.y + 'px';
					finalVelMagnitude.textContent = Math.round(finalMagnitude);

					let clipVelocityLoss = enterMagnitude - diagram.magnitude;
					let flattenLoss = diagram.magnitude - finalMagnitude;
					let totalLoss = clipVelocityLoss + flattenLoss;

					statusMaintained.textContent = "velocity maintained after bounce: " + Math.round(finalMagnitude / enterMagnitude * 100) + "%";
					statusContributorClipVelocity.textContent = Math.round(clipVelocityLoss / enterMagnitude * 100) + "% decrease during ClipVelocity";
					statusContributorFlattening.textContent = Math.round(flattenLoss / diagram.magnitude * 100) + "% decrease during velocity flattening";
				};
			}

			let animationFrameRequest;
			function startAnimation(options) {
				let last = performance.now();

				animationFrameRequest = requestAnimationFrame(function animate(time) {
					let dt = time - last;
					// the start can actually get a negative value for some reason
					// so clamp it
					if (dt > 0) {
						options.update(dt / 1000);
					}
					last = time;
					animationFrameRequest = requestAnimationFrame(animate);
				});
			}

			let enterAngle = 40;
			let angleDir = -1;
			let angleChange = 10;
			let enterAngleDir = 1;
			let enterAngleChange = 7;
			startAnimation({
				update: function(dt) {
					diagram.angle += angleDir * angleChange * dt;
					if (diagram.angle < -40) {
						diagram.angle = -40;
						angleDir *= -1;
					} else if (diagram.angle > -10) {
						diagram.angle = -10;
						angleDir *= -1;
					}
					enterAngle += enterAngleDir * enterAngleChange * dt;
					if (enterAngle > 45) {
						enterAngle = 45;
						enterAngleDir *= -1;
					} else if (enterAngle < 5) {
						enterAngle = 5;
						enterAngleDir *= -1;
					}
					diagram.updateEnterAngle(enterAngle);
					diagram.update();
				}
			});
		};

		let initFFDiagram = function() {
			let diagram = new RampslideDiagram(
				document.getElementById('clipvelocity-fortressforever'), 
				{angle: -30, magnitude: 700, offset: 0, alwaysParallel: true}
			);

			{
				let enterAngle = 15;
				let cappedEnterAngle = enterAngle;
				let enterMagnitude = 700;
				let finalMagnitude = 100; // TODO
				let beforeVelWidth = 200;
				let finalVelArrowContainer = diagram.root.querySelector('.velocity-arrow-final-container');
				let finalVelArrow = finalVelArrowContainer.querySelector('.velocity-arrow');
				let finalVelMagnitude = finalVelArrowContainer.querySelector('.velocity-magnitude');
				let beforeVelArrowContainer = diagram.root.querySelector('.velocity-arrow-enter-container');
				let beforeVelArrow = beforeVelArrowContainer.querySelector('.velocity-arrow');
				let beforeVelMagnitude = beforeVelArrowContainer.querySelector('.velocity-magnitude');
				let slopeAngleControl = diagram.root.querySelector('.controls .controls-slope-angle');
				let velocityAngleControl = diagram.root.querySelector('.controls .controls-velocity-angle');
				let tickRate = 66;
				let tick = 1/tickRate;
				let stepSize = 18;

				let calcEntrySpeedForBounce = function(velocityAngle, slopeAngle) {
					let slopeAngleRadians = slopeAngle / 180 * Math.PI;
					let necessaryDistanceInOneTick = stepSize / Math.tan(slopeAngleRadians);
					let necessaryBounceSpeed = necessaryDistanceInOneTick / tick;
					let postClipVelocityYComponent = (-necessaryBounceSpeed) * Math.tan(slopeAngleRadians);
					let postClipVelocity = new Vec2d(necessaryBounceSpeed, postClipVelocityYComponent);
					// To get the pre-ClipVelocity magnitude, we get a normalized version of the
					// clipped velocity and then use its length to get back to what the initial velocity's
					// magnitude would need to be to produce the calculated postClipVelocity result
					let normalizedClipVelocity = clipVelocity(getVector(velocityAngle, 1), getNormal(slopeAngle));
					let necessaryMagnitude = postClipVelocity.length() / normalizedClipVelocity.length();
					return {enterMagnitude: necessaryMagnitude, clippedVelocity: postClipVelocity, bounceSpeed: necessaryBounceSpeed};
				};

				diagram.updateEnterAngle = function(newAngle) {
					enterAngle = newAngle;
					cappedEnterAngle = Math.max(-90, diagram.angle - enterAngle);
					let results = calcEntrySpeedForBounce(cappedEnterAngle, diagram.angle);
					enterMagnitude = results.enterMagnitude;
					diagram.magnitude = results.clippedVelocity.length();
					finalMagnitude = Math.abs(results.bounceSpeed);
				};

				diagram.updateEnterAngle(enterAngle);

				diagram.onupdate = function() {
					let afterVelRect = diagram.velocityArrowContainer.getBoundingClientRect();
					let containerRect = diagram.root.getBoundingClientRect();
					let enterAnchorRelative = new Vec2d(
						afterVelRect.right - containerRect.left,
						afterVelRect.top - containerRect.top
					);
					beforeVelArrowContainer.style.left=enterAnchorRelative.x + 'px';
					beforeVelArrowContainer.style.top=enterAnchorRelative.y + 'px';
					beforeVelArrowContainer.style.transform = 'rotate('+cappedEnterAngle+'deg) translate(0, -3px)';
					beforeVelMagnitude.innerHTML = '&ge; ' + Math.round(enterMagnitude);
					finalVelArrowContainer.style.right=(containerRect.right - afterVelRect.right) + 'px';
					finalVelArrowContainer.style.top=enterAnchorRelative.y + 'px';
					finalVelMagnitude.innerHTML = '&ge; ' + Math.round(finalMagnitude);
				};

				slopeAngleControl.oninput = function() {
					diagram.angle = -(this.value);
					diagram.updateEnterAngle(enterAngle);
					diagram.update();
				};
				velocityAngleControl.oninput = function() {
					diagram.updateEnterAngle(this.value);
					diagram.updateExcludeSlope();
				};
			}

			diagram.update();
		};

		let ready = function() {
			initClipVelocityDiagram();
			initFlatteningDiagram();
			initStayOnGroundDiagram({
				suffix: 'goldsrc',
				scale: 0.05,
				magnitude: 4,
				threshold: 2,
				min: 1,
				max: 6,
				decimal: true,
			});
			initStayOnGroundDiagram({
				suffix: 'source',
				scale: 0.3,
				magnitude: 31,
				threshold: 18,
				min: 16,
				max: 48,
			});
			initBounceSpeedDiagram();
			initFFDiagram();
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
			left: 50px;
			width: 400px;
			height: 5px;
			background-color: black;
			transform-origin: 0% 100%;
			transform: rotate(-30deg);
		}
		@media (prefers-color-scheme: dark) {
		.rampsliding-diagram .slope {
			background-color: #ddd;
		}
		}
		.rampsliding-diagram .slope-angle {
			position: absolute;
			bottom: 35px;
			right: 60px;
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
			border-left: 0; border-bottom: 0;
			width: 399px; height: 399px;
			right: 0px; bottom: 0px;
			border-radius: 0 100% 0 0;
			transform-origin: 0 100%;
			transform: rotate(60deg);
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
		#clipvelocity-bounce .velocity-arrow-container .velocity-arrow {
			width: 58.3333px;
		}
		#clipvelocity-bounce .velocity-arrow-enter-container {
			left: 216.7px; top: 102.683px; transform: rotate(-30deg) translate(0px, -3px);
		}
		#clipvelocity-bounce .velocity-arrow-enter-container .velocity-arrow {
			width: 116.667px;
		}
		.rampsliding-diagram .velocity-arrow-final-container {
			position: absolute;
			width: 150px;
			z-index: 5;
			right: 253.3px; top: 232.683px;
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
		.rampsliding-diagram .velocity-arrow {
			background-color: #ddd;
		}
		}
		@media (prefers-color-scheme: dark) {
		.rampsliding-diagram .velocity-arrow::after { 
			border-right-color: #ddd;
		}
		}
		.rampsliding-diagram.bouncing .velocity-arrow {
			background-color: #5A06CC;
		}
		.rampsliding-diagram.bouncing .velocity-arrow::after {
			border-right-color: #5A06CC;
		}
		.rampsliding-diagram .velocity-magnitude {
			position: absolute;
			left: 50%;
			bottom: 0em;
			font-size: 90%;
			transform: translate(-50%, 0);
		}
		.rampsliding-diagram .stepsize-components {
			position: absolute;
			border-left: 1px dashed;
			border-color: rgba(0,0,0,.5);
			z-index: 4;
		}
		@media (prefers-color-scheme: dark) {
		.rampsliding-diagram .stepsize-components {
			border-color: rgba(255,255,255,.5);
		}
		}
		.rampsliding-diagram .stepsize-components .height {
			position:absolute;
			right: 100%;
			margin-right: 1em;
			top: 50%;
			transform: translate(0, -50%);
			text-align: right;
			color: red;
			font-weight: bold;
		}
		.rampsliding-diagram.bouncing .stepsize-components .height {
			color: green;
		}
		.rampsliding-diagram .controls {
			position:absolute;
			left: 0px; right: 0px; top: 1em;
			text-align: center;
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
			left: 50px;
			width: 200px;
			transform-origin: 0% 100%;
			transform: rotate(-30deg) translate(0px, -20px);
			z-index: 5;
		}
		#clipvelocity-enter-example.rampsliding-diagram .velocity-components {
			left: 113.583px; bottom: 147.317px;
			width: 174.7px; height: 102.6px;
		}
		.rampsliding-diagram .loss-contributors {
			opacity: 0.85;
			font-style: italic;
			font-size: 85%;
		}
		@media (prefers-color-scheme: dark) {
		.rampsliding-diagram .slope-angle-lock {
			background-color: #333;
		}
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
		#clipvelocity-enter-example .velocity-arrow-container .velocity-arrow {
			background-color: #5A06CC;
		}
		#clipvelocity-enter-example .velocity-arrow-container .velocity-arrow::after {
			border-right-color: #5A06CC;
		}
		#clipvelocity-bounce .velocity-arrow-container .velocity-arrow .velocity-magnitude {
			display: none;
		}
		#clipvelocity-bounce .velocity-arrow-container .velocity-arrow,
		#diagram-bounce-speed .velocity-arrow-container .velocity-arrow {
			background-color: #645175;
			background: repeating-linear-gradient(
			  90deg,
			  transparent,
			  transparent 5px,
			  #645175 5px,
			  #645175 10px
			);
			opacity: 0.5;
		}
		#clipvelocity-bounce .velocity-arrow-container .velocity-arrow::after,
		#diagram-bounce-speed .velocity-arrow-container .velocity-arrow::after {
			border-right-color: #645175;
		}
		#clipvelocity-bounce .velocity-arrow-final-container .velocity-arrow,
		#diagram-bounce-speed .velocity-arrow-final-container .velocity-arrow {
			background-color: #5A06CC;
		}
		#clipvelocity-bounce .velocity-arrow-final-container .velocity-arrow::after,
		#diagram-bounce-speed .velocity-arrow-final-container .velocity-arrow::after {
			border-right-color: #5A06CC;
		}
		#clipvelocity-stayonground-source.rampsliding-diagram,
		#clipvelocity-stayonground-goldsrc.rampsliding-diagram {
			height: 300px;
		}
		#diagram-bounce-speed.rampsliding-diagram {
			height: 475px;
		}
		#clipvelocity-fortressforever.rampsliding-diagram .velocity-arrow {
			width: 150px;
		}
		.rampsliding-diagram .stepsize-value {
			position:absolute;
			left: 0px; right: 0px; bottom: 40px;
			text-align: center;
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
	</style>
</div>