extends Resource
class_name VehicleConfig
## All tunable numbers of a car, as a Godot resource.
##
## Design rule: nothing in the vehicle code contains magic numbers. Every value the
## physics, the drivetrain, the steering or the visuals need lives here so a car can be
## re-tuned (or an entirely new car created) purely with data, from the editor or from a
## .tres file. Scripts must never be edited to change how a car feels.

@export_group("Mass and body")
## Total mass of the vehicle in kilograms. Heavier cars accelerate slower, brake longer
## and survive contacts better.
@export_range(400.0, 12000.0, 5.0) var mass: float = 1450.0
## Height of the centre of mass above the chassis origin. Lower = harder to roll over.
@export_range(0.05, 1.2, 0.01) var center_of_mass_height: float = 0.42
## Overall dimensions (length, height, width) used for the collision box and visuals.
@export var body_size: Vector3 = Vector3(1.86, 0.72, 4.45)
## Fraction of the mass kept on the front axle when standing still (0..1).
@export_range(0.3, 0.7, 0.01) var front_weight_ratio: float = 0.53

@export_group("Engine and drivetrain")
## Peak engine torque in newton metres, scaled by the drivetrain and wheel radius.
@export_range(50.0, 3000.0, 5.0) var engine_torque: float = 420.0
## Engine speed (in "rpm"-like units) at which the torque curve starts to fall off.
@export_range(500.0, 12000.0, 50.0) var peak_torque_rpm: float = 4200.0
## Hard engine speed limit; beyond it torque collapses to zero.
@export_range(1000.0, 16000.0, 50.0) var max_rpm: float = 6800.0
## Idle engine speed.
@export_range(0.0, 3000.0, 10.0) var idle_rpm: float = 800.0
## Overall gear ratio (approximated single-speed final drive for an arcade drivetrain).
@export_range(0.5, 12.0, 0.05) var final_drive: float = 3.6
## Drive layout: 0 = rear wheel drive, 1 = front wheel drive, 2 = all wheel drive.
@export_enum("RWD", "FWD", "AWD") var drive_layout: int = 0
## How much torque is sent to the front axle in AWD mode (0..1).
@export_range(0.0, 1.0, 0.05) var awd_front_split: float = 0.42
## How quickly the engine reaches its target rpm (1/s). Bigger = snappier throttle.
@export_range(1.0, 30.0, 0.5) var rpm_response: float = 9.0
## Wheel radius in metres (also used for speed-from-rpm maths).
@export_range(0.2, 0.9, 0.01) var wheel_radius: float = 0.34
## Reverse gear torque multiplier.
@export_range(0.1, 1.5, 0.05) var reverse_torque_scale: float = 0.55
## Reverse speed limit as a fraction of the forward top speed.
@export_range(0.05, 0.8, 0.01) var reverse_speed_ratio: float = 0.28

@export_group("Speed envelope")
## Hard forward speed cap in metres per second (the arcade "top speed").
@export_range(5.0, 150.0, 0.5) var max_speed: float = 46.0
## Aerodynamic drag coefficient (force = drag * v^2).
@export_range(0.0, 8.0, 0.01) var drag_coefficient: float = 0.42
## Rolling resistance coefficient (force = rolling * mass * g).
@export_range(0.0, 0.2, 0.001) var rolling_resistance: float = 0.014
## Extra downward force scaling with speed, keeps the car planted at high speed.
@export_range(0.0, 40.0, 0.1) var downforce: float = 6.0

@export_group("Brakes")
## Service brake torque in newton metres per wheel.
@export_range(200.0, 20000.0, 50.0) var brake_torque: float = 5200.0
## Handbrake torque applied to the rear wheels only.
@export_range(200.0, 30000.0, 50.0) var handbrake_torque: float = 9000.0
## Fraction of rear lateral grip removed while the handbrake is held (0..1).
@export_range(0.0, 1.0, 0.02) var handbrake_grip_loss: float = 0.62
## Brake balance towards the front axle (0..1).
@export_range(0.2, 0.9, 0.01) var brake_bias: float = 0.62

@export_group("Tyres and steering")
## Peak lateral friction coefficient of the tyres.
@export_range(0.3, 3.0, 0.01) var tyre_grip: float = 1.16
## Slip angle (radians) at which the tyre reaches peak lateral force.
@export_range(0.02, 0.6, 0.005) var peak_slip_angle: float = 0.14
## Slip angle (radians) beyond which the tyre is fully sliding.
@export_range(0.05, 1.2, 0.005) var slide_slip_angle: float = 0.42
## Force multiplier while the tyre is beyond the slide angle (drift feel).
@export_range(0.3, 1.2, 0.01) var slide_grip_scale: float = 0.86
## Maximum steering angle of the front wheels in degrees.
@export_range(5.0, 60.0, 0.5) var max_steer_angle_deg: float = 34.0
## How quickly the steering moves towards the requested angle (degrees per second).
@export_range(30.0, 1200.0, 5.0) var steer_speed_deg: float = 260.0
## Steering angle reduction at top speed (0 = none, 1 = fully locked at top speed).
@export_range(0.0, 0.95, 0.01) var speed_steer_reduction: float = 0.62
## Extra angular damping applied when no steering input is given.
@export_range(0.0, 6.0, 0.05) var straighten_assist: float = 1.5
## Counter-steer help for touch controls (0 = raw, 1 = strong help).
@export_range(0.0, 1.0, 0.02) var counter_steer_assist: float = 0.35

@export_group("Suspension")
## Rest length of the wheel springs in metres.
@export_range(0.05, 0.6, 0.01) var suspension_rest_length: float = 0.28
## Suspension travel in metres.
@export_range(0.05, 0.6, 0.01) var suspension_travel: float = 0.22
## Spring stiffness per wheel in newtons per metre.
@export_range(5000.0, 200000.0, 100.0) var suspension_stiffness: float = 46000.0
## Damping per wheel.
@export_range(500.0, 20000.0, 50.0) var suspension_damping: float = 3600.0
## Anti-roll distribution between axles (0..1).
@export_range(0.0, 1.0, 0.02) var anti_roll: float = 0.35

@export_group("Stability helpers")
## Maximum linear speed the physics is allowed to reach (safety net for contacts).
@export_range(20.0, 300.0, 1.0) var velocity_clamp: float = 90.0
## Linear damping applied to the chassis.
@export_range(0.0, 2.0, 0.01) var linear_damping: float = 0.08
## Angular damping applied to the chassis.
@export_range(0.0, 4.0, 0.01) var angular_damping: float = 1.1
## Extra force that pushes the chassis back down when airborne and tilting.
@export_range(0.0, 20.0, 0.1) var air_stability: float = 3.0
## Nitro configuration used by this car (may be null for cars without nitro).
@export var nitro: NitroConfig = null
## Visual scale of the wheels.
@export_range(0.5, 2.0, 0.01) var wheel_width: float = 0.24


## Top speed in km/h, for UI and tests.
func max_speed_kmh() -> float:
	return max_speed * 3.6


## Reverse top speed in m/s.
func reverse_max_speed() -> float:
	return max_speed * reverse_speed_ratio


## Suspension force for a given compression (pure helper, unit tested).
func suspension_force(compression: float) -> float:
	var clamped := clampf(compression, 0.0, suspension_travel)
	return clamped * suspension_stiffness


## Damper force for a given compression velocity (pure helper, unit tested).
func damper_force(velocity: float) -> float:
	return -velocity * suspension_damping
