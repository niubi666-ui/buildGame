extends RefCounted
## What every level's map must describe. terrain_data.gd keeps the live heights, and asks one of
## these for the starting shape and for where things belong.


## Natural ground. It must also make sense far outside the map, for the distant hills.
func base_height(_x: float, _z: float) -> float:
	return 0.0


## Starting ground at one point: x is the height, y how deep it counts as dug, z how much road is here.
func sample(x: float, z: float) -> Vector3:
	return Vector3(base_height(x, z), 0.0, 0.0)


func home() -> Vector2:
	return Vector2.ZERO


## Enemies have arrived once they are this close to home.
func goal_radius() -> float:
	return 0.0


## Each point is inside a body of water that exists at the start.
func water_seeds() -> Array[Vector2]:
	return []


## Metres to the nearest road. Trees keep their distance.
func road_distance(_x: float, _z: float) -> float:
	return INF


## Circles with no trees, each as x, z, radius.
func keep_clear() -> Array[Vector3]:
	return []


## Circles the player cannot sculpt or build in, each as x, z, radius.
func no_build_zones() -> Array[Vector3]:
	return []


## Circles of loose boulders, each as x, z, radius.
func rock_patches() -> Array[Vector3]:
	return []


func lantern_spots() -> Array[Vector2]:
	return []


## A few words for which way a route goes, from trace data: four floats per point, ending in the mode.
func describe_route(_points: PackedFloat32Array) -> String:
	return ""
