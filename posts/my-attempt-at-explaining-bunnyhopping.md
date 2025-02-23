- An understanding of the core principle
- An understand of all the different pieces and how they interact
- An understanding of all the gameplay-relevant effects

<div style="text-align: center;">
<video autoplay loop muted style="margin-left:auto; margin-right:auto; display: block;">
	<source src="/images/explaining-bunnyhopping/bhop.mp4" type="video/mp4">
</video>
<i class="caption">An example of bunnyhopping from <a href="https://www.youtube.com/watch?v=TcZMnw461cQ">this video</a></i>
</div>

foo

<div id="normal-keystate" class="keystate">
	<div class="keyboard-container">
		<div class="keyboard"><div class="top-row"><span class="keyboard-key">↑</span></div><div class="bottom-row"><span class="keyboard-key pressed">←</span><span class="keyboard-key">↓</span><span class="keyboard-key">→</span></div></div>
	</div>
	<div class="mouse-container"><img class="mouse" src="/images/explaining-bunnyhopping/computer-mouse-icon.svg" /></div>
</div>

foo

<div style="text-align: center;">
	<div id="speed-loss-example" class="bunnyhopping-diagram">
		<div class="view-direction-arrow-container">
			<div class="arrow">
			</div>
		</div>
		<div class="view-direction-symbol">👁</div>
		<div class="wish-direction-arrow-container">
			<div class="arrow">
			</div>
		</div>
		<div class="wish-direction-projection"></div>
		<div class="velocity-arrow-container">
			<div class="arrow">
				<div class="velocity-magnitude">700</div>
			</div>
		</div>
		<div style="border-right: 1px dotted white; position: absolute; left: 50%; bottom: 25%; width: 105px; height: 180px"></div>
		<div class="result-velocity-arrow-container">
			<div class="arrow">
				<div class="velocity-magnitude">700</div>
			</div>
		</div>
		<div class="wish-direction-keys">
			<div class="keyboard-mini"><div class="top-row"><span class="keyboard-key">▲</span></div><div class="bottom-row"><span class="keyboard-key pressed">◄</span><span class="keyboard-key">▼</span><span class="keyboard-key">►</span></div></div>
		</div>
	</div>
</div>

<style scoped>
#speed-loss-example .velocity-arrow-container {
	transform: rotate(120deg);
}
#speed-loss-example .velocity-arrow-container .arrow {
	width: 200px;
}
#speed-loss-example .view-direction-symbol {
	bottom: calc(25% - 60px);
	left: 50%;
	transform: translate(-50%, 100%);
}
</style>

foo

<div style="text-align: center;">
	<div id="velocity-example" class="bunnyhopping-diagram">
		<div class="status">
			<div class="no-change">No speed change</div>
			<div class="increasing active">Gaining speed<span class="speed-gain"></span></div>
			<div class="decreasing">Losing speed<span class="speed-loss"></span></div>
		</div>
		<div class="view-direction-arrow-container">
			<div class="arrow">
			</div>
		</div>
		<div class="view-direction-symbol">👁</div>
		<div class="wish-direction-arrow-container">
			<div class="arrow">
			</div>
		</div>
		<div class="wish-direction-projection"></div>
		<div class="velocity-arrow-container">
			<div class="arrow">
				<div class="velocity-magnitude">700</div>
			</div>
		</div>
		<div class="result-velocity-arrow-container">
			<div class="arrow">
				<div class="velocity-magnitude">700</div>
			</div>
		</div>
		<div class="angle-results-container">
			<div class="angle-results"></div>
		</div>
		<div class="wish-direction-keys">
			<div class="keyboard-mini"><div class="top-row"><span class="keyboard-key">▲</span></div><div class="bottom-row"><span class="keyboard-key pressed">◄</span><span class="keyboard-key">▼</span><span class="keyboard-key">►</span></div></div>
		</div>
	</div>
</div>

## admin he doing it sideways

<div style="text-align: center;">
	<div id="sideways-example" class="bunnyhopping-diagram">
		<div class="status">
			<div class="no-change">No speed change</div>
			<div class="increasing active">Gaining speed<span class="speed-gain"></span></div>
			<div class="decreasing">Losing speed<span class="speed-loss"></span></div>
		</div>
		<div class="view-direction-arrow-container">
			<div class="arrow">
			</div>
		</div>
		<div class="view-direction-symbol">👁</div>
		<div class="wish-direction-arrow-container">
			<div class="arrow">
			</div>
		</div>
		<div class="wish-direction-projection"></div>
		<div class="velocity-arrow-container">
			<div class="arrow">
				<div class="velocity-magnitude">700</div>
			</div>
		</div>
		<div class="result-velocity-arrow-container">
			<div class="arrow">
				<div class="velocity-magnitude">700</div>
			</div>
		</div>
		<div class="angle-results-container">
			<div class="angle-results"></div>
		</div>
		<div class="wish-direction-keys">
			<div class="keyboard-mini"><div class="top-row"><span class="keyboard-key pressed">▲</span></div><div class="bottom-row"><span class="keyboard-key">◄</span><span class="keyboard-key">▼</span><span class="keyboard-key">►</span></div></div>
		</div>
	</div>
</div>

move mouse right when pressing down, left when pressing up

<div>

<style scoped>
#sideways-example .velocity-arrow-container, #sideways-example .result-velocity-arrow-container {
	bottom: 40%;
}
#sideways-example .angle-results-container {
	bottom: 40%;
	transform: translate(-50%, 0) rotate(90deg);
	transform-origin: 50% 100%;
}
#sideways-example .wish-direction-arrow-container {
	bottom: 40%;
	transform: rotate(90deg);
}
#sideways-example .wish-direction-projection {
	bottom: 40%;
	transform: rotate(90deg);
	transform-origin: 50% 100%;
}
#sideways-example .wish-direction-keys {
	bottom: 40%;
	transform: translate(-50%, -60px);
}
#sideways-example .view-direction-arrow-container {
	bottom: calc(40% - 60px);
}
#sideways-example .view-direction-symbol {
	bottom: calc(40% - 60px);
	left: 50%;
	transform: translate(-50%, 100%);
}
</style>

</div>

## Why not press forward?

It might make some intuitive sense to think that, since acceleration is applied based on your wish direction, then having a wish direction that is more forwards would increase the amount of speed gained (or minimize the amount of potential speed lost due to the acceleration being applied counter to the current velocity).

However, as we've established, the 'sweet spot' is purely determined by your wish direction, not your view direction, so if you press both forwards and left, then your wish direction will have a 45 degree difference from your view direction, and therefore the perfect angle between your view direction and your velocity is also 45 degrees.

<div style="text-align: center;">
	<div id="press-forwards-angle" class="bunnyhopping-diagram">
		TODO: remove empty space from this diagram
		<div class="view-direction-arrow-container">
			<div class="arrow">
			</div>
		</div>
		<div class="view-direction-symbol">👁</div>
		<div class="wish-direction-arrow-container">
			<div class="arrow">
			</div>
		</div>
		<div class="angle-results-container">
			<div class="angle-results"></div>
		</div>
		<div class="wish-direction-keys">
			<div class="keyboard-mini"><div class="top-row"><span class="keyboard-key forward pressed">▲</span></div><div class="bottom-row"><span class="keyboard-key left pressed">◄</span><span class="keyboard-key backward">▼</span><span class="keyboard-key right">►</span></div></div>
		</div>
	</div>
</div>

<style scoped>
#press-forwards-angle .angle-results-container {
	transform: translate(-50%, 0) rotate(45deg);
	transform-origin: 50% 100%;
}
#press-forwards-angle .wish-direction-arrow-container {
	bottom: 25%;
	transform: rotate(45deg);
}
#press-forwards-angle .wish-direction-projection {
	bottom: 25%;
	transform: rotate(45deg);
	transform-origin: 50% 100%;
}
#press-forwards-angle .view-direction-symbol {
	bottom: calc(25% - 60px);
	left: 50%;
	transform: translate(-50%, 100%);
}
#press-forwards-angle .wish-direction-keys {
	transform: translate(calc(-50% - (.7071*80px)), calc(50% - (.7071*80px)));
}
</style>

It is much more difficult finding and maintaining this 45 degree angle, and it means that will not be able to fully look (and aim/shoot) where you are going while bunnyhopping.

Also note that, when not pressing forward, switching between strafing left and strafing right allows you to start gaining speed again immediately, as the sweet spot remains unchanged.

<div style="text-align: center;">
	<div id="no-press-forwards-example" class="bunnyhopping-diagram">
		TODO: remove empty space from this diagram
		<div class="view-direction-arrow-container">
			<div class="arrow">
			</div>
		</div>
		<div class="view-direction-symbol">👁</div>
		<div class="wish-direction-arrow-container">
			<div class="arrow">
			</div>
		</div>
		<div class="angle-results-container">
			<div class="angle-results"></div>
		</div>
		<div class="wish-direction-keys">
			<div class="keyboard-mini"><div class="top-row"><span class="keyboard-key forward">▲</span></div><div class="bottom-row"><span class="keyboard-key left pressed">◄</span><span class="keyboard-key backward">▼</span><span class="keyboard-key right">►</span></div></div>
		</div>
	</div>
</div>

<style scoped>
#no-press-forwards-example .view-direction-symbol {
	bottom: calc(25% - 60px);
	left: 50%;
	transform: translate(-50%, 100%);
}
</style>

When pressing forward and a strafe direction, however, the sweet spot shifts dramatically, so you have to readjust your view direction by 90 degrees to start gaining speed again.

<div style="text-align: center;">
	<div id="press-forwards-example" class="bunnyhopping-diagram">
		<div class="status">
			<div class="no-change">No speed change</div>
			<div class="increasing active">Gaining speed</div>
			<div class="decreasing">Losing speed</div>
		</div>
		<div class="view-direction-arrow-container">
			<div class="arrow">
			</div>
		</div>
		<div class="view-direction-symbol">👁</div>
		<div class="wish-direction-arrow-container">
			<div class="arrow">
			</div>
		</div>
		<div class="wish-direction-projection"></div>
		<div class="velocity-arrow-container">
			<div class="arrow">
				<div class="velocity-magnitude" style="display:none;">700</div>
			</div>
		</div>
		<div class="result-velocity-arrow-container">
			<div class="arrow">
				<div class="velocity-magnitude" style="display:none;">700</div>
			</div>
		</div>
		<div class="angle-results-container">
			<div class="angle-results"></div>
		</div>
		<div class="wish-direction-keys">
			<div class="keyboard-mini"><div class="top-row"><span class="keyboard-key forward pressed">▲</span></div><div class="bottom-row"><span class="keyboard-key left pressed">◄</span><span class="keyboard-key backward">▼</span><span class="keyboard-key right">►</span></div></div>
		</div>
	</div>
</div>

<style scoped>
#press-forwards-example .angle-results-container {
	transform: translate(-50%, 0) rotate(45deg);
	transform-origin: 50% 100%;
}
#press-forwards-example .wish-direction-arrow-container {
	bottom: 25%;
	transform: rotate(45deg);
}
#press-forwards-example .wish-direction-projection {
	bottom: 25%;
	transform: rotate(45deg);
	transform-origin: 50% 100%;
}
#press-forwards-example .view-direction-symbol {
	bottom: calc(25% - 60px);
	left: 50%;
	transform: translate(-50%, 100%);
}
#press-forwards-example .wish-direction-keys {
	transform: translate(calc(-50% - (.7071*80px)), calc(50% - (.7071*80px)));
}
</style>

With the added difficulty of trying to align your view 45 degrees off from your velocity, there is nothing but downsides to pressing forwards while bunnyhopping.

### The Quake III tangent

Quake III movement does not have the wishSpd clamp, which means that the 'losing speed' threshold is the same but the 'gaining speed' threshold is much, much larger

This means press forwards because ???

https://github.com/id-Software/Quake-III-Arena/blob/dbe4ddb10315479fc00086f08e25d968b4b43c49/code/game/bg_pmove.c#L246-L247

## Going for distance

foo

<div style="text-align: center;">
<video autoplay loop muted style="margin-left:auto; margin-right:auto; display: block;">
	<source src="/images/explaining-bunnyhopping/kz_long_jump.mp4" type="video/mp4">
</video>
<i class="caption">Long jumping in CSGO KZ from <a href="https://www.youtube.com/watch?v=UjzBefsaWqk">this video</a></i>
</div>

<p><aside class="note">

Confession: For a long time, I assumed there was some amount of placebo effect going on with this technique, but I couldn't have been more wrong.

</aside></p>

<div style="text-align: center;">
	<div id="kz-long-jump-principle" class="bunnyhopping-diagram">
		<div class="start-status">Starting speeds: 250</div>
		<div class="end-status">Final speeds: <span class="ending-speed">264</span></div>
	</div>
	<i class="caption">Switching directions allows you to get closer to traveling in a straight line (without sacrificing any speed)</i>
</div>

foo

<div style="text-align: center;">
	<div id="kz-long-jump" class="bunnyhopping-diagram">
	</div>
	<i class="caption">Perpendicular distance traveled increases with the frequency of direction switches</i>
</div>

### The inhuman limit

foo

<div style="text-align: center;">
	<div id="kz-long-jump-inhuman" class="bunnyhopping-diagram">
	</div>
</div>

<style scoped>
#kz-long-jump {
	height: 500px;
}
#kz-long-jump-inhuman {
	height: 500px;
}
.bunnyhopping-diagram .start-status, .bunnyhopping-diagram .end-status {
	margin: 3px;
	padding: 3px;
	background: #0e0e0e;
}
.bunnyhopping-diagram .end-status {
	position: absolute;
	bottom: 0px;
	width: calc(100% - 12px);
	z-index: 6;
}
.precise-arrow {
	transform: translate(0, -50%);
	transform-origin: 0 50%;
	height: 2px;
	width: 190px;
	background: #D0BDE0;
	position: absolute;
	left: 50%;
	top: 50%;
	z-index: 5;
}
.precise-arrow::after {
	content: '';
	width: 0; 
	height: 0; 
	border-top: 4px solid transparent;
	border-bottom: 4px solid transparent;
	border-left: 10px solid #D0BDE0;
	position: absolute;
	right: -10px;
	top: -3px;
	z-index: 5;
}
.precise-arrow.accel {
	background: repeating-linear-gradient( 90deg, transparent, transparent 5px, #5C9FD3 5px, #5C9FD3 8px );
}
.precise-arrow.accel::after {
	border-left-color: #5C9FD3;
	border-top: 3px solid transparent;
	border-bottom: 3px solid transparent;
	border-left-width: 6px;
	position: absolute;
	right: -5px;
	top: -2px;
}
.ruler {
	border-left: 1px dotted #88ff88;
	position: absolute;
	z-index: 1;
	height: 100%;
	left: 50%;
}
.distance-marker {
	border-top: 1px dotted white;
	position: absolute;
	z-index: 2;
	width: 100%;
	top: 50%;
}
</style>

## sv_airaccelerate

### TFC crouch

foo

https://www.youtube.com/watch?v=TWcKrzBOd-E

<div style="text-align: center; width: 80%; margin-left: auto; margin-right: auto;">
<video autoplay loop muted style="margin-left:auto; margin-right:auto; display: block; width: 50%; float: left;">
	<source src="/images/explaining-bunnyhopping/great_scoop_up_by_rizzo.mp4" type="video/mp4">
</video>
<video autoplay loop muted style="margin-left:auto; margin-right:auto; display: block; width: 50%; float: right;">
	<source src="/images/explaining-bunnyhopping/great_scoop_up_by_rizzo_crouched.mp4" type="video/mp4">
</video>
<i class="caption">The same technique performed while uncrouched (left) and crouched (right)</i>
</div>

<div class="keyboard"><div class="top-row"><span class="keyboard-key">↑</span></div><div class="bottom-row"><span class="keyboard-key pressed">←</span><span class="keyboard-key">↓</span><span class="keyboard-key">→</span></div></div>

- Everything in the 'gaining speed' zone ends up with the same angle of the result vector, and it's always on the cutoff of the 'no speed change' zone.
- No speed change cutoff is determined by the angle of the result vector from gaining speed.
- At lower speeds, the clamped wishSpd is the same, which means that the result vector angle is greater. This means that at lower speeds the angle threshold is wider, and at higher speeds the angle threshold is lower.
- sv_airaccelerate doesn't alter the thresholds but affects the result vector angle. Lower airaccel means a smaller difference in angle between the starting velocity and the result velocity across the board. Higher airaccel means a larger difference in angle between the starting velocity and the result velocity, meaning that if you turn too quickly you end up back on the edge of the 'no speed loss' zone after one tick and therefore don't lose more speed on the next tick. With lower airaccel, if you turn too quick you may stay in the 'losing speed' zone for multiple ticks and compound the effect.
- Quake III movement does not have the wishSpd clamp, which means that the 'losing speed' threshold is the same but the 'gaining speed' threshold is much, much larger
- In TFC, crouching in the air lowers your wishSpeed, leading to similar effects as lower sv_airaccelerate

<script>
// this is mostly a sloppy mess
/* jshint esversion: 6 */
(function() {
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
		add(other) {
			return new Vec2d(this.x+other.x, this.y+other.y);
		}
		mulScalar(scalar) {
			return new Vec2d(this.x*scalar, this.y*scalar);
		}
	}

	// Returns the dot product of the velocity and the wishDir as currentSpeed.
	// Returns the modification that should be made to velocity as velocityDelta.
	// Does not modify velocity itself.
	let airAccel = function(velocity, dt, wishDir, wishSpeed, accel) {
		let wishSpd = (wishSpeed > 30) ? 30 : wishSpeed;

		const currentSpeed = velocity.dot(wishDir);

		const addSpeed = wishSpd - currentSpeed;
		if (addSpeed <= 0)
			return { currentSpeed: currentSpeed, accelSpeed: 0, velocityDelta: new Vec2d(0,0) }

		let accelSpeed = accel * wishSpeed * dt;
		if (accelSpeed > addSpeed) {
			accelSpeed = addSpeed;
		}

		return { currentSpeed: currentSpeed, accelSpeed: accelSpeed, velocityDelta: wishDir.mulScalar(accelSpeed) };
	};

	let getVector = function(angle, magnitude) {
		// 0 angle corresponds to Vec2d(0, 1)
		let radians = (90+angle) / 180 * Math.PI;
		let x = Math.cos(radians) * magnitude;
		let y = Math.sin(radians) * magnitude;
		// reverse x so that we're moving left
		return new Vec2d(-x, y);
	};

	class BunnyhopDiagram {

		constructor(root, startingValues, onupdate) {
			this.root = root;
			this.onupdate = onupdate;
			this.velocityArrowContainer = root.querySelector('.velocity-arrow-container');
			this.velocityArrow = this.velocityArrowContainer.querySelector('.arrow');
			this.velocityMagnitude = this.velocityArrowContainer.querySelector('.velocity-magnitude');
			this.resultVelocityArrowContainer = root.querySelector('.result-velocity-arrow-container');
			this.resultVelocityArrow = this.resultVelocityArrowContainer.querySelector('.arrow');
			this.resultVelocityMagnitude = this.resultVelocityArrowContainer.querySelector('.velocity-magnitude');
			this.status = root.querySelector('.status');
			this.angle = startingValues.angle;
			this.magnitude = startingValues.magnitude;
			this.velocity = this.getVelocity(this.magnitude);
			this.scale = startingValues.scale || 2.2;
			this.wishDir = startingValues.wishDir || new Vec2d(-1, 0);
		}


		getVelocity(magnitude) {
			return getVector(this.angle, magnitude || this.magnitude);
		}

		getWishDirection() {
			return this.wishDir;
		}

		getViewDirection() {
			return new Vec2d(0, 1);
		}

		updateValues() {
			this.velocity = this.getVelocity();
			const sv_airaccelerate = 10;
			const wishSpeed = 400;
			const ticksPerSec = 60;
			const {currentSpeed, accelSpeed, velocityDelta} = airAccel(this.velocity, 1/ticksPerSec, this.getWishDirection(), wishSpeed, sv_airaccelerate);
			const newVelocity = this.velocity.add(velocityDelta);
			const velDelta = newVelocity.length() - this.magnitude;
			this.magnitude = this.velocity.length();
			this.resultMagnitude = newVelocity.length();
			this.resultAngle = 90 - (Math.atan2(newVelocity.y, newVelocity.x) * 180 / Math.PI);
		}

		updateVelocity() {
			this.velocityArrowContainer.style.transform = 'rotate(' + (90+this.angle) + 'deg)';
			this.velocityArrow.style.width = (this.magnitude / this.scale) + 'px';
			this.velocityMagnitude.innerHTML = Math.round(this.magnitude);

			this.resultVelocityArrowContainer.style.transform = 'rotate(' + (90+this.resultAngle) + 'deg)';
			this.resultVelocityArrow.style.width = (this.resultMagnitude / this.scale) + 'px';
			this.resultVelocityMagnitude.innerHTML = Math.round(this.resultMagnitude);

			const magnitudeDelta = this.resultMagnitude - this.magnitude;
			if (Math.abs(magnitudeDelta) <= Number.EPSILON) {
				this.status.querySelector('.no-change').classList.add('active');
				this.status.querySelector('.increasing').classList.remove('active');
				this.status.querySelector('.decreasing').classList.remove('active');
				const speedGain = this.status.querySelector('.speed-gain');
				const speedLoss = this.status.querySelector('.speed-loss');
				if (speedGain) speedGain.style.display = 'none';
				if (speedLoss) speedLoss.style.display = 'none';
			} else if (magnitudeDelta > 0) {
				this.status.querySelector('.no-change').classList.remove('active');
				this.status.querySelector('.increasing').classList.add('active');
				this.status.querySelector('.decreasing').classList.remove('active');
				const speedGain = this.status.querySelector('.speed-gain');
				const speedLoss = this.status.querySelector('.speed-loss');
				if (speedGain) {
					speedGain.textContent = '+'+magnitudeDelta.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
					speedGain.style.display = 'block';
				}
				if (speedLoss) {
					speedLoss.style.display = 'none';
				}
			} else {
				this.status.querySelector('.no-change').classList.remove('active');
				this.status.querySelector('.increasing').classList.remove('active');
				this.status.querySelector('.decreasing').classList.add('active');
				const speedGain = this.status.querySelector('.speed-gain');
				const speedLoss = this.status.querySelector('.speed-loss');
				if (speedLoss) {
					speedLoss.textContent = magnitudeDelta.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
					speedLoss.style.display = 'block';
				}
				if (speedGain) {
					speedGain.style.display = 'none';
				}
			}
		}

		update() {
			this.updateValues();
			this.updateVelocity();

			if (this.onupdate) {
				this.onupdate(this);
			}
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

		let diagram = new BunnyhopDiagram(
			document.getElementById('velocity-example'), 
			{angle: 0, magnitude: 500}
		);

		let timing = function(timeFraction) { return timeFraction; };
		let toTheRight = { duration: 10000, timing,
			draw: function(progress) {
				diagram.angle = 0 + 10 * progress;
				diagram.update();
			}
		};
		let swingBack = { duration: 20000, timing,
			draw: function(progress) {
				diagram.angle = 10 - 20 * progress;
				diagram.update();
			}
		};
		let leftToMiddle = { duration: 10000, timing,
			draw: function(progress) {
				diagram.angle = -10 + 10 * progress;
				diagram.update();
			}
		};
		toTheRight.next = swingBack;
		swingBack.next = leftToMiddle;
		leftToMiddle.next = toTheRight;
		startAnimation(toTheRight);
	};

	let initSidewaysDiagram = function() {
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

		let diagram = new BunnyhopDiagram(
			document.getElementById('sideways-example'), 
			{angle: 90, magnitude: 500, wishDir: new Vec2d(0,1)}
		);

		let timing = function(timeFraction) { return timeFraction; };
		let toTheRight = { duration: 10000, timing,
			draw: function(progress) {
				diagram.angle = 90 + 10 * progress;
				diagram.update();
			}
		};
		let swingBack = { duration: 20000, timing,
			draw: function(progress) {
				diagram.angle = 100 - 20 * progress;
				diagram.update();
			}
		};
		let leftToMiddle = { duration: 10000, timing,
			draw: function(progress) {
				diagram.angle = 80 + 10 * progress;
				diagram.update();
			}
		};
		toTheRight.next = swingBack;
		swingBack.next = leftToMiddle;
		leftToMiddle.next = toTheRight;
		startAnimation(toTheRight);
	};

	let initNoPressForwardsDiagram = function() {
		const rootElement = document.getElementById('no-press-forwards-example');
		const angleResults = rootElement.querySelector('.angle-results-container');
		const wishDirectionArrow = rootElement.querySelector('.wish-direction-arrow-container');
		const wishDirectionKeys = rootElement.querySelector('.wish-direction-keys');

		var strafingLeft = true;
		setInterval(function() {
			if (!strafingLeft) {
				angleResults.style.transform = 'translate(-50%, 0)';
				wishDirectionArrow.style.transform = 'rotate(0deg)';
				wishDirectionKeys.style.transform = 'translate(-100px, 50%)';
				wishDirectionKeys.querySelector('.right').classList.remove('pressed');
				wishDirectionKeys.querySelector('.left').classList.add('pressed');
			} else {
				angleResults.style.transform = 'translate(-50%, 0) scale(-1, 1)';
				wishDirectionArrow.style.transform = 'translate(0, -2px) rotate(180deg)';
				wishDirectionKeys.style.transform = 'translate(60px, 50%)';
				wishDirectionKeys.querySelector('.left').classList.remove('pressed');
				wishDirectionKeys.querySelector('.right').classList.add('pressed');
			}
			strafingLeft = !strafingLeft;
		}, 1200);
	};

	let initPressForwardsDiagram = function() {
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
					if (options.init != undefined) {
						options.init();
					}
				}
			});
		}

		const rootElement = document.getElementById('press-forwards-example');
		const angleResults = rootElement.querySelector('.angle-results-container');
		const wishDirectionArrow = rootElement.querySelector('.wish-direction-arrow-container');
		const wishDirectionProjection = rootElement.querySelector('.wish-direction-projection');
		const wishDirectionKeys = rootElement.querySelector('.wish-direction-keys');
		let diagram = new BunnyhopDiagram(
			rootElement,
			{angle: 45, magnitude: 500, wishDir: new Vec2d(-1/Math.sqrt(2), 1/Math.sqrt(2))}
		);

		let timing = function(timeFraction) { return timeFraction; };
		let pressingLeftForward = { duration: 1000, timing,
			draw: function(progress) {},
			init: function() {
				diagram.wishDir.x = -diagram.wishDir.x;
				angleResults.style.transform = 'translate(-50%, 0) rotate(-45deg) scale(-1, 1)';
				wishDirectionArrow.style.transform = 'rotate(135deg)';
				wishDirectionProjection.style.transform = 'rotate(135deg)';
				wishDirectionKeys.style.transform = 'translate(calc(-50% + (.7071*80px)), calc(50% - (.7071*80px)))';
				wishDirectionKeys.querySelector('.left').classList.remove('pressed');
				wishDirectionKeys.querySelector('.right').classList.add('pressed');
			}
		};
		let switchToRightForward = { duration: 1000, timing,
			draw: function(progress) {
				diagram.angle = 45 - 90 * progress;
				diagram.update();
			}
		};
		let pressingRightForward = { duration: 1000, timing,
			draw: function(progress) {},
			init: function() {
				diagram.wishDir.x = -diagram.wishDir.x;
				angleResults.style.transform = 'translate(-50%, 0) rotate(45deg)';
				wishDirectionArrow.style.transform = 'rotate(45deg)';
				wishDirectionProjection.style.transform = 'rotate(45deg)';
				wishDirectionKeys.style.transform = 'translate(calc(-50% - (.7071*80px)), calc(50% - (.7071*80px)))';
				wishDirectionKeys.querySelector('.right').classList.remove('pressed');
				wishDirectionKeys.querySelector('.left').classList.add('pressed');
			}
		};
		let switchToLeftForward = { duration: 1000, timing,
			draw: function(progress) {
				diagram.angle = -45 + 90 * progress;
				diagram.update();
			}
		};
		pressingLeftForward.next = switchToRightForward;
		switchToRightForward.next = pressingRightForward;
		pressingRightForward.next = switchToLeftForward;
		switchToLeftForward.next = pressingLeftForward;
		startAnimation(pressingLeftForward);
	};

	class LongJumpDiagram {

		constructor(root, startingValues) {
			this.root = root;
			this.dt = startingValues.dt || 1/60;
			this.scale = startingValues.scale || 10;
			this.accelScale = startingValues.accelScale || 1;
			this.startingY = startingValues.startingY || 25;
			this.startingX = startingValues.startingX || 0;
			this.sv_airaccelerate = startingValues.sv_airaccelerate || 10;
			this.runspeed = startingValues.runspeed || 250;
			this.initialSpeed = startingValues.initialSpeed || this.runspeed;
			this.dirFn = startingValues.dirFn || (function() { return -1; });
			this.numTicks = startingValues.numTicks || 8;
		}

		draw() {
			let velocity = new Vec2d(0, -this.runspeed);
			let position = new Vec2d(0,0);

			const ruler = document.createElement('div');
			ruler.classList.add('ruler');
			ruler.style.left = (this.startingX - 1)+'px';
			this.root.appendChild(ruler);

			let dir = -1;
			for (let i=0; i<=this.numTicks; i++) {
				const movement = velocity.mulScalar(this.dt * this.scale);
				this.drawVec(movement, position, i/this.numTicks);
				position = position.add(movement);

				if (i == this.numTicks) break;

				const strafeLeft = new Vec2d(velocity.y, -velocity.x).normalize();
				const strafeRight = new Vec2d(-velocity.y, velocity.x).normalize();
				dir = this.dirFn(i, dir, this.numTicks);
				const wishDir = dir == -1 ? strafeLeft : strafeRight;
				const {currentSpeed, accelSpeed, velocityDelta} = airAccel(velocity, this.dt, wishDir, this.runspeed, this.sv_airaccelerate);
				this.drawVec(velocityDelta.mulScalar(this.accelScale), position, undefined, 'accel');

				velocity = velocity.add(velocityDelta);
			}

			const distMarker = document.createElement('div');
			distMarker.classList.add('distance-marker');
			distMarker.style.top = (this.startingY - position.y)+'px';
			this.root.appendChild(distMarker);

			const endSpeedStatus = this.root.querySelector('.ending-speed')
			if (endSpeedStatus) {
				endSpeedStatus.textContent = Math.round(velocity.length());
			}
		}

		drawVec(vec, pos, colorPercent, additionalClass) {
			const dist = vec.length();
			const arrow = document.createElement('div');
			arrow.classList.add('precise-arrow');
			if (additionalClass) {
				arrow.classList.add(additionalClass);
			}
			let angle = -(Math.atan2(vec.y, vec.x) * 180 / Math.PI);
			arrow.style.transform = 'translate(0, -50%) rotate('+angle+'deg)';
			arrow.style.left = (this.startingX + pos.x)+'px';
			arrow.style.top = (this.startingY - pos.y)+'px';
			arrow.style.width = Math.max(0,dist-10)+'px';
			if (colorPercent != undefined) {
				arrow.style.filter = 'brightness('+(100-colorPercent*25)+'%) hue-rotate('+(0-colorPercent*10)+'deg) saturate('+(100+colorPercent*250)+'%)';
			}
			this.root.appendChild(arrow);
		}
	}

	let initKzLongJump = function() {
		const kz_long_jump_principle = document.getElementById("kz-long-jump-principle");
		const noTurn = new LongJumpDiagram(kz_long_jump_principle, {
			startingY: 50,
			startingX: 200,
			scale: 8,
			numTicks: 8,
		});
		noTurn.draw();
		const withTurn = new LongJumpDiagram(kz_long_jump_principle, {
			startingY: 50,
			startingX: 350,
			scale: 8,
			numTicks: 8,
			dirFn: function(i, cur) {
				if (i < 4) return cur;
				if (i == 4) return -cur;
				return cur;
			}
		});
		withTurn.draw();

		const kz_long_jump = document.getElementById("kz-long-jump");
		const zigzigAccelScale = 0.75;
		const zigzag16 = new LongJumpDiagram(kz_long_jump, {
			startingX: 150,
			scale: 4,
			numTicks: 24,
			accelScale: zigzigAccelScale,
			dirFn: function(i, cur) {
				if (i < 8) return cur;
				if ((i+8) % 16 == 0) return -cur;
				return cur;
			}
		});
		zigzag16.draw();
		const zigzag12 = new LongJumpDiagram(kz_long_jump, {
			startingX: 225,
			scale: 4,
			numTicks: 24,
			accelScale: zigzigAccelScale,
			dirFn: function(i, cur) {
				if (i < 6) return cur;
				if ((i+6) % 12 == 0) return -cur;
				return cur;
			}
		});
		zigzag12.draw();
		const zigzag8 = new LongJumpDiagram(kz_long_jump, {
			startingX: 300,
			scale: 4,
			numTicks: 24,
			accelScale: zigzigAccelScale,
			dirFn: function(i, cur) {
				if (i < 4) return cur;
				if ((i+4) % 8 == 0) return -cur;
				return cur;
			}
		});
		zigzag8.draw();
		const zigzag6 = new LongJumpDiagram(kz_long_jump, {
			startingX: 375,
			scale: 4,
			numTicks: 24,
			accelScale: zigzigAccelScale,
			dirFn: function(i, cur) {
				if (i < 3) return cur;
				if ((i+3) % 6 == 0) return -cur;
				return cur;
			}
		});
		zigzag6.draw();
		const zigzag4 = new LongJumpDiagram(kz_long_jump, {
			startingX: 450,
			scale: 4,
			numTicks: 24,
			accelScale: zigzigAccelScale,
			dirFn: function(i, cur) {
				if (i < 2) return cur;
				if ((i+2) % 4 == 0) return -cur;
				return cur;
			}
		});
		zigzag4.draw();

		const kz_long_jump_inhuman = document.getElementById('kz-long-jump-inhuman');
		const zigzag1 = new LongJumpDiagram(kz_long_jump_inhuman, {
			startingY: 50,
			startingX: 150,
			scale: 10,
			numTicks: 8,
			accelScale: zigzigAccelScale,
			dirFn: function(i, cur) {
				return -cur;
			}
		});
		zigzag1.draw();
		const zigzag2 = new LongJumpDiagram(kz_long_jump_inhuman, {
			startingY: 50,
			startingX: 350,
			scale: 10,
			numTicks: 8,
			accelScale: zigzigAccelScale,
			dirFn: function(i, cur) {
				if (i % 2 != 0) return -cur;
				return cur;
			}
		});
		zigzag2.draw();
	};

	let ready = function() {
		initDiagram1();
		initSidewaysDiagram();
		initNoPressForwardsDiagram();
		initPressForwardsDiagram();
		initKzLongJump();
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
:root {
	--view-direction-color: #6A08C4;
}

.keystate {
	width: 300px;
	margin: 0 auto;
	display: grid;
	grid-template-columns: 1fr 1fr;
}
.keystate .mouse-container {
	height: 100%;
	background: #aaa;
	position: relative;
}
.keystate .mouse-container .mouse {
	position: absolute;
	width: 32px;
	left: 0;
	top: 20px;
}

.bunnyhopping-diagram {
	margin-right: auto; margin-left: auto; display: block;
	width: 500px; height: 400px;
	position: relative;
	background-color: #eee;
	overflow: hidden;
}
@media (prefers-color-scheme: dark) {
.bunnyhopping-diagram {
	background-color: #111;
}
}
.bunnyhopping-diagram .status {
	display: grid;
	grid-template-columns: 1fr 1fr 1fr;
	grid-gap: 3px;
	padding: 3px;
}
.bunnyhopping-diagram .status > * {
	opacity: 0.25;
}
.bunnyhopping-diagram .status .no-change {
	background: #666;
	position: relative;
}
.bunnyhopping-diagram .status .increasing {
	background: #4A7641;
	position: relative;
}
.bunnyhopping-diagram .status .decreasing {
	background: #562929;
	position: relative;
}
.bunnyhopping-diagram .status .active {
	opacity: 1;
}
.bunnyhopping-diagram .status .speed-gain, .bunnyhopping-diagram .status .speed-loss {
	position: absolute;
	bottom: -100%;
	width: 100%;
	text-align: center;
}
.bunnyhopping-diagram .status .speed-gain {
	color: green;
}
.bunnyhopping-diagram .status .speed-loss {
	color: red;
}
.bunnyhopping-diagram .velocity-magnitude {
	position: absolute;
	left: 50%;
	bottom: 0em;
	font-size: 90%;
	transform: translate(-50%, 0);
}
.bunnyhopping-diagram .arrow {
	position: absolute;
	bottom: 0px;
	right: 0px;
	width: 50px;
	height: 2px;
	margin-left: 10px;
	transform-origin: 100% 100%;
	transform: none;
	background-color: black;
	z-index: 5;
}
@media (prefers-color-scheme: dark) {
.bunnyhopping-diagram .arrow {
	background-color: #ddd;
}
}
.bunnyhopping-diagram .arrow::after { 
	content: '';
	width: 0; 
	height: 0; 
	border-top: 5px solid transparent;
	border-bottom: 5px solid transparent;
	border-right: 20px solid black;
	position: absolute;
	left: -10px;
	top: -4px;
	z-index: 5;
}
@media (prefers-color-scheme: dark) {
.bunnyhopping-diagram .arrow::after { 
	border-right-color: #ddd;
}
}
.view-direction-symbol {
	position: absolute;
	text-align: center;
	line-height: 20px;
	width: 20px;
	height: 20px;
	background-color: var(--view-direction-color);
	border-radius: 50%;
	z-index: 10;
	pointer-events: none;
}
#velocity-example .view-direction-symbol {
	bottom: calc(25% - 60px);
	left: 50%;
	transform: translate(-50%, 100%);
}
.bunnyhopping-diagram .view-direction-arrow-container {
	position: absolute;
	bottom: calc(25% - 60px);
	right: 50%;
	width: 60px;
	transform-origin: 100% 50%;
	transform: rotate(90deg);
	z-index: 6;
}
@media (prefers-color-scheme: dark) {
.bunnyhopping-diagram .view-direction-arrow-container .arrow {
	background-color: var(--view-direction-color);
}
.bunnyhopping-diagram .view-direction-arrow-container .arrow::after {
	border-right-color: var(--view-direction-color);
}
}
.bunnyhopping-diagram .wish-direction-arrow-container {
	position: absolute;
	bottom: 25%;
	right: 50%;
	width: 60px;
	transform-origin: 100% 100%;
	transform: rotate(0deg);
	z-index: 5;
}
.bunnyhopping-diagram .wish-direction-arrow-container .arrow {
}
@media (prefers-color-scheme: dark) {
.bunnyhopping-diagram .wish-direction-arrow-container .arrow {
	background-color: #C5B07A;
}
.bunnyhopping-diagram .wish-direction-arrow-container .arrow::after {
	border-right-color: #C5B07A;
}
}
.bunnyhopping-diagram .wish-direction-projection {
	position: absolute;
	bottom: 25%;
	right: 0;
	width: 100%;
	height: 2px;
	transform-origin: 100% 100%;
	transform: rotate(0deg);
	z-index: 4;
	background: repeating-linear-gradient( 90deg, transparent, transparent 5px, #584B2B 5px, #584B2B 10px );
}
@media (prefers-color-scheme: dark) {
.bunnyhopping-diagram .wish-direction-projection {
	background: repeating-linear-gradient( 90deg, transparent, transparent 5px, #C5B07A 5px, #C5B07A 6px );
}
}
.bunnyhopping-diagram .wish-direction-keys {
	position: absolute;
	z-index: 5;
	left: 50%;
	bottom: 25%;
	transform: translate(-100px, 50%);
	border-radius: 50%;
	width: 40px;
	height: 40px;
	pointer-events: none;
	background-color: #C5B07A;
}
.bunnyhopping-diagram .wish-direction-keys .keyboard-mini {
	transform: translate(0, -5px);
}
.bunnyhopping-diagram .wish-direction-keys .keyboard-key {
	opacity: 0.5;
}
.bunnyhopping-diagram .wish-direction-keys .pressed {
	opacity: 1;
}
.bunnyhopping-diagram .velocity-arrow-container {
	position: absolute;
	bottom: 25%;
	right: 50%;
	width: 200px;
	transform-origin: 100% 100%;
	transform: rotate(90deg);
	z-index: 5;
}
.bunnyhopping-diagram .result-velocity-arrow-container {
	position: absolute;
	bottom: 25%;
	right: 50%;
	width: 200px;
	transform-origin: 100% 100%;
	transform: rotate(90deg);
	z-index: 5;
}
@media (prefers-color-scheme: dark) {
.bunnyhopping-diagram .result-velocity-arrow-container .arrow {
	background: repeating-linear-gradient( 90deg, transparent, transparent 5px, #5C9FD3 5px, #5C9FD3 10px );
}
.bunnyhopping-diagram .result-velocity-arrow-container .arrow::after {
	border-right-color: #5C9FD3;
}
}
.caption {
	background-color: rgba(0,0,0, .1);
	margin:0; padding: .25em;
	width: auto;
	max-width: 75%; display: inline-block;
	margin-left: auto; margin-right: auto;
}

.angle-results-container {
	position: absolute;
	bottom: 25%;
	left: 50%;
	transform: translate(-50%, 0);
	width: 500px;
	height: 250px;
	overflow: hidden;
}

.angle-results {
	background: conic-gradient(green 0deg, lightgreen 4deg, rgba(255,0,0,0.25) 4.5deg, rgba(0,0,0,0) 90deg, rgba(0,0,0,0) 270deg, rgba(150,150,150,.25) 356deg, lightgreen 358deg, green 360deg);
	border-radius: 50%;
	width: 500px;
	height: 500px;
/*	opacity: 0.5;*/
	--mask: radial-gradient(rgba(0,0,0,1) 25%, rgba(0,0,0,0) 50%);
	-webkit-mask: var(--mask); 
	mask: var(--mask);
}


.keyboard .keyboard-key {
	width: 25px;
	height: 25px;
	font-size: 15px;
	line-height: 15px;
	margin: 5px;
	margin-bottom: 6px;
	color: rgb(80,80,80);
	box-shadow:
		0px 1px 0px rgb(250, 250, 250),
		0px 2px 0px rgb(250, 250, 250),
		0px 3px 0px rgb(250, 250, 250),
		0px 4px 0px 1px rgb(130, 130, 130),
		0px 4px 0px 2px rgb(70, 70, 70);
	background: rgb(249,249,249);
	background: linear-gradient(to bottom, rgb(249,249,249) 0%,rgb(239,239,239) 95%,rgb(226,226,226) 100%);

	border-radius: 3px;
	box-sizing: border-box;
	overflow: hidden;
	text-align: center;
	padding-top: 8px;
}
.keyboard .top-row .keyboard-key {
	display: inline-block;
	margin-bottom: 0;
}
.keyboard .bottom-row {
	clear:both;
}
.keyboard .bottom-row .keyboard-key {
	display: block;
	float: left;
}
.keyboard {
	display: inline-block;
	text-align: center;
	vertical-align: baseline;
}
.keyboard .keyboard-key.pressed {
	color: rgb(10,10,25);
	background: #67BCE0;
	background: linear-gradient(to bottom, #94DFED 0%,#7FD1E0 95%,#73C5D4 100%);
	box-shadow:
		0px 0px 0px 1px rgb(130, 130, 130),
		0px 1px 0px 1px rgb(70, 70, 70);
	margin-top: 9px;
}

.keyboard-mini .keyboard-key {
	width: 10px;
	height: 10px;
	font-size: 8px;
	line-height: 10px;
	margin: 1px;
	margin-bottom: 6px;
	color: rgb(80,80,80);
	box-shadow:
		0px 0px 0px 1px rgb(130, 130, 130),
		0px 1px 0px 1px rgb(70, 70, 70);
	background: rgb(249,249,249);

	border-radius: 3px;
	box-sizing: border-box;
	overflow: hidden;
	text-align: center;
}
.keyboard-mini .top-row {
	line-height: 16px;
}
.keyboard-mini .top-row .keyboard-key {
	display: inline-block;
	margin-bottom: 0;
}
.keyboard-mini .bottom-row {
	clear:both;
}
.keyboard-mini .bottom-row .keyboard-key {
	display: block;
	float: left;
}
.keyboard-mini {
	display: inline-block;
	text-align: center;
}
.keyboard-mini .keyboard-key.pressed {
	color: rgb(10,10,25);
	background: #67BCE0;
	background: linear-gradient(to bottom, #94DFED 0%,#7FD1E0 95%,#73C5D4 100%);
	box-shadow:
		0px 0px 0px 1px rgb(130, 130, 130);
	margin-top: 2px;
}
</style>

</div>