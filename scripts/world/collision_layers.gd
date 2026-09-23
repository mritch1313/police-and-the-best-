extends RefCounted
class_name CollisionLayers
## The physics layers of the game, in one place.
##
## Godot gives every physics object a 32 bit layer and a 32 bit mask, and a mobile project
## must keep the broad phase small: the fewer pairs of objects that can ever collide, the
## fewer contact tests the CPU has to run every frame. These constants are the single source
## of truth used by the world, the vehicles and the sensors.
##
## layer 1 = ground and roads        (the floor everything drives on)
## layer 2 = buildings and walls     (static, tall)
## layer 3 = props and parkour       (kerbs, containers, benches, barriers)
## layer 4 = the player
## layer 5 = police units
## layer 6 = ambient traffic
## layer 7 = sensors and triggers    (areas that never collide with anything solid)
## layer 8 = debris and small objects thrown around by impacts

const GROUND := 1 << 0
const BUILDING := 1 << 1
const PROP := 1 << 2
const PLAYER := 1 << 3
const POLICE := 1 << 4
const TRAFFIC := 1 << 5
const SENSOR := 1 << 6
const DEBRIS := 1 << 7

## Everything a car drives and collides on.
const SOLID_WORLD := GROUND | BUILDING | PROP
## Everything a car can physically hit.
const VEHICLE_COLLISION := SOLID_WORLD | PLAYER | POLICE | TRAFFIC | DEBRIS
## What the suspension raycast looks for (only the ground: a car never drives up a wall).
const WHEEL_RAY := GROUND | BUILDING | PROP
## What the chase camera avoids (walls and buildings, never cars).
const CAMERA_BLOCKERS := GROUND | BUILDING | PROP
## What the AI vision raycast looks through.
const AI_VISION_BLOCKERS := BUILDING | PROP


## Human readable name of a layer mask, for the debug overlay.
static func describe_layer(layer: int) -> String:
	var names := PackedStringArray()
	if layer & GROUND:
		names.append("ground")
	if layer & BUILDING:
		names.append("building")
	if layer & PROP:
		names.append("prop")
	if layer & PLAYER:
		names.append("player")
	if layer & POLICE:
		names.append("police")
	if layer & TRAFFIC:
		names.append("traffic")
	if layer & SENSOR:
		names.append("sensor")
	if layer & DEBRIS:
		names.append("debris")
	return ", ".join(names)
