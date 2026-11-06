// Exposes pathcore::World to GDScript as a class named PathCore.
// Talks to Godot's C interface directly, so the project needs no generated bindings.
#include "gdextension_interface.h"
#include "path_core.h"

#include <cmath>
#include <cstring>
#include <new>
#include <vector>

namespace {

using pathcore::World;

GDExtensionClassLibraryPtr g_library = nullptr;
GDExtensionInterfaceVariantNewCopy variant_new_copy = nullptr;
GDExtensionInterfaceVariantDestroy variant_destroy = nullptr;
GDExtensionInterfaceVariantGetType variant_get_type = nullptr;
GDExtensionInterfaceGetVariantFromTypeConstructor get_from_type = nullptr;
GDExtensionInterfaceGetVariantToTypeConstructor get_to_type = nullptr;
GDExtensionInterfaceVariantGetPtrConstructor get_constructor = nullptr;
GDExtensionInterfaceVariantGetPtrDestructor get_destructor = nullptr;
GDExtensionInterfaceVariantGetPtrBuiltinMethod get_builtin = nullptr;
GDExtensionInterfaceStringNameNewWithUtf8Chars string_name_new = nullptr;
GDExtensionInterfaceStringNewWithUtf8Chars string_new = nullptr;
GDExtensionInterfacePackedFloat32ArrayOperatorIndex float_index = nullptr;
GDExtensionInterfacePackedFloat32ArrayOperatorIndexConst float_index_const = nullptr;
GDExtensionInterfacePackedByteArrayOperatorIndexConst byte_index_const = nullptr;
GDExtensionInterfacePackedByteArrayOperatorIndex byte_index = nullptr;
GDExtensionInterfaceClassdbConstructObject3 construct_object = nullptr;
GDExtensionInterfaceObjectSetInstance object_set_instance = nullptr;
GDExtensionInterfaceClassdbRegisterExtensionClass6 register_class = nullptr;
GDExtensionInterfaceClassdbRegisterExtensionClassMethod register_method = nullptr;
GDExtensionInterfaceClassdbUnregisterExtensionClass unregister_class = nullptr;
GDExtensionInterfacePrintErrorWithMessage print_error = nullptr;

GDExtensionPtrBuiltInMethod float_array_resize = nullptr;
GDExtensionPtrConstructor float_array_new = nullptr;
GDExtensionPtrDestructor float_array_free = nullptr;
GDExtensionPtrDestructor byte_array_free = nullptr;
GDExtensionPtrBuiltInMethod byte_array_resize = nullptr;
GDExtensionPtrConstructor byte_array_new = nullptr;

struct Opaque8 {
	alignas(8) unsigned char data[8];
};
struct Opaque16 {
	alignas(8) unsigned char data[16];
};
struct OpaqueVariant {
	alignas(8) unsigned char data[24];
};

Opaque8 g_class_name;
Opaque8 g_parent_name;

Opaque8 *make_name(const char *text) {
	// Kept for the life of the library, as Godot reads these when methods are listed.
	Opaque8 *name = new Opaque8();
	string_name_new(name, text);
	return name;
}

Opaque8 *make_string(const char *text) {
	Opaque8 *value = new Opaque8();
	string_new(value, text);
	return value;
}

double read_number(GDExtensionConstVariantPtr value) {
	const GDExtensionVariantType type = variant_get_type(value);
	if (type == GDEXTENSION_VARIANT_TYPE_INT) {
		int64_t out = 0;
		get_to_type(GDEXTENSION_VARIANT_TYPE_INT)(&out, const_cast<GDExtensionVariantPtr>(value));
		return static_cast<double>(out);
	}
	if (type == GDEXTENSION_VARIANT_TYPE_FLOAT) {
		double out = 0.0;
		get_to_type(GDEXTENSION_VARIANT_TYPE_FLOAT)(&out, const_cast<GDExtensionVariantPtr>(value));
		return out;
	}
	return 0.0;
}

void return_float(GDExtensionVariantPtr target, double value) {
	OpaqueVariant boxed;
	get_from_type(GDEXTENSION_VARIANT_TYPE_FLOAT)(&boxed, &value);
	variant_new_copy(target, &boxed);
	variant_destroy(&boxed);
}

void return_int(GDExtensionVariantPtr target, int64_t value) {
	OpaqueVariant boxed;
	get_from_type(GDEXTENSION_VARIANT_TYPE_INT)(&boxed, &value);
	variant_new_copy(target, &boxed);
	variant_destroy(&boxed);
}

void return_floats(GDExtensionVariantPtr target, const std::vector<float> &values) {
	Opaque16 array;
	float_array_new(&array, nullptr);
	if (!values.empty()) {
		const int64_t size = static_cast<int64_t>(values.size());
		const GDExtensionConstTypePtr args[1] = { &size };
		int64_t result = 0;
		float_array_resize(&array, args, &result, 1);
		std::memcpy(float_index(&array, 0), values.data(), values.size() * sizeof(float));
	}
	OpaqueVariant boxed;
	get_from_type(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY)(&boxed, &array);
	variant_new_copy(target, &boxed);
	variant_destroy(&boxed);
	float_array_free(&array);
}

void return_bytes(GDExtensionVariantPtr target, const std::vector<uint8_t> &values) {
	Opaque16 array;
	byte_array_new(&array, nullptr);
	if (!values.empty()) {
		const int64_t size = static_cast<int64_t>(values.size());
		const GDExtensionConstTypePtr args[1] = { &size };
		int64_t result = 0;
		byte_array_resize(&array, args, &result, 1);
		std::memcpy(byte_index(&array, 0), values.data(), values.size());
	}
	OpaqueVariant boxed;
	get_from_type(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY)(&boxed, &array);
	variant_new_copy(target, &boxed);
	variant_destroy(&boxed);
	byte_array_free(&array);
}

std::vector<float> read_floats(GDExtensionConstVariantPtr value, int count) {
	Opaque16 array;
	get_to_type(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY)(&array, const_cast<GDExtensionVariantPtr>(value));
	std::vector<float> out(count);
	if (count > 0) {
		std::memcpy(out.data(), float_index_const(&array, 0), count * sizeof(float));
	}
	float_array_free(&array);
	return out;
}

enum Method {
	M_CONFIGURE,
	M_SET_VOID_LEVEL,
	M_SET_TYPE,
	M_SET_ACTIVE_TYPES,
	M_SET_GATES,
	M_OPTION_COSTS,
	M_VIA_COSTS,
	M_ADD_TUNNEL,
	M_REMOVE_TUNNEL,
	M_BEGIN_WAVE,
	M_ADD_GROUP,
	M_FINISH_WAVE,
	M_TAKE_IMPACTS,
	M_TAKE_LAUNCHES,
	M_TAKE_DEATHS,
	M_EARNED,
	M_SET_TERRAIN,
	M_SOLVE,
	M_COST_AT,
	M_TRACE,
	M_STEP,
	M_BOATS,
	M_BRIDGES,
	M_FORGET_BRIDGES,
	M_ARRIVED,
	M_ACTIVE,
	M_CANDIDATES,
	M_SHOTS,
	M_KILLS,
	M_ADD_TOWER,
	M_REMOVE_TOWER,
	M_SET_TOWER_AIM,
	M_TOWER_KILLS,
	M_VISIBILITY,
	M_COVERED,
	M_BEST_AIM,
	M_SET_TOWER_STATS,
	M_TOWER_VISIBILITY,
	M_TOWER_COVERED,
	M_TOWER_BEST_AIM,
	M_FIRES,
	M_STONES,
	M_STATS_VISIBILITY,
	M_STATS_COVERED,
	M_STATS_BEST_AIM,
};

// Arguments, in order: apex x, y, z, aim x, y, z, half angle in radians, range.
pathcore::Cone read_cone(const GDExtensionConstVariantPtr *args) {
	pathcore::Cone cone;
	cone.x = static_cast<float>(read_number(args[0]));
	cone.y = static_cast<float>(read_number(args[1]));
	cone.z = static_cast<float>(read_number(args[2]));
	cone.dx = static_cast<float>(read_number(args[3]));
	cone.dy = static_cast<float>(read_number(args[4]));
	cone.dz = static_cast<float>(read_number(args[5]));
	cone.cos_half = std::cos(static_cast<float>(read_number(args[6])));
	cone.range = static_cast<float>(read_number(args[7]));
	return cone;
}

// Just the apex and aim, from the first six arguments. The stats list fills in the rest.
pathcore::Cone read_at(const GDExtensionConstVariantPtr *args) {
	pathcore::Cone cone;
	cone.x = static_cast<float>(read_number(args[0]));
	cone.y = static_cast<float>(read_number(args[1]));
	cone.z = static_cast<float>(read_number(args[2]));
	cone.dx = static_cast<float>(read_number(args[3]));
	cone.dy = static_cast<float>(read_number(args[4]));
	cone.dz = static_cast<float>(read_number(args[5]));
	return cone;
}

void method_call(void *userdata, GDExtensionClassInstancePtr instance, const GDExtensionConstVariantPtr *args, GDExtensionInt count, GDExtensionVariantPtr ret, GDExtensionCallError *error) {
	World *world = static_cast<World *>(instance);
	error->error = GDEXTENSION_CALL_OK;
	switch (static_cast<Method>(reinterpret_cast<intptr_t>(userdata))) {
		case M_SET_VOID_LEVEL:
			world->settings.void_level = static_cast<float>(read_number(args[0]));
			break;
		case M_CONFIGURE:
			world->settings.min_gap_depth = static_cast<float>(read_number(args[0]));
			world->settings.max_span = static_cast<float>(read_number(args[1]));
			world->settings.tunnel_speed = static_cast<float>(read_number(args[2]));
			break;
		case M_SET_TYPE: {
			// Order: walk, uphill, climb, climb slope, boat, embark, bridge, crew, hp, reward, r, g, b, scale.
			const std::vector<float> p = read_floats(args[1], 14);
			pathcore::UnitType type;
			type.walk_speed = p[0];
			type.uphill_penalty = p[1];
			type.climb_speed = p[2];
			type.climb_slope = p[3];
			type.boat_speed = p[4];
			type.embark_time = p[5];
			type.bridge_time = p[6];
			type.crew = p[7];
			type.hp = p[8];
			type.reward = p[9];
			type.r = p[10];
			type.g = p[11];
			type.b = p[12];
			type.scale = p[13];
			world->set_type(static_cast<int>(read_number(args[0])), type);
			break;
		}
		case M_SET_ACTIVE_TYPES: {
			const std::vector<float> p = read_floats(args[0], static_cast<int>(read_number(args[1])));
			std::vector<int> types;
			for (const float value : p) {
				types.push_back(static_cast<int>(value));
			}
			world->set_active_types(types);
			break;
		}
		case M_SET_GATES:
			world->set_gates(read_floats(args[0], static_cast<int>(read_number(args[1]))));
			break;
		case M_OPTION_COSTS:
			return_floats(ret, world->option_costs(static_cast<int>(read_number(args[0])), static_cast<int>(read_number(args[1]))));
			break;
		case M_VIA_COSTS:
			return_floats(ret, world->via_costs(static_cast<int>(read_number(args[0])), static_cast<float>(read_number(args[1])), static_cast<float>(read_number(args[2]))));
			break;
		case M_ADD_TUNNEL:
			return_int(ret, world->add_tunnel(static_cast<float>(read_number(args[0])), static_cast<float>(read_number(args[1])), static_cast<float>(read_number(args[2])), static_cast<float>(read_number(args[3]))));
			break;
		case M_REMOVE_TUNNEL:
			world->remove_tunnel(static_cast<int>(read_number(args[0])));
			break;
		case M_BEGIN_WAVE:
			world->begin_wave();
			break;
		case M_ADD_GROUP:
			world->add_group(static_cast<int>(read_number(args[0])), static_cast<float>(read_number(args[1])), static_cast<float>(read_number(args[2])), static_cast<int>(read_number(args[3])), static_cast<float>(read_number(args[4])), static_cast<float>(read_number(args[5])));
			break;
		case M_FINISH_WAVE:
			world->finish_wave();
			break;
		case M_TAKE_IMPACTS:
			return_floats(ret, world->take_impacts());
			break;
		case M_TAKE_LAUNCHES:
			return_floats(ret, world->take_launches());
			break;
		case M_TAKE_DEATHS:
			return_floats(ret, world->take_deaths());
			break;
		case M_EARNED:
			return_float(ret, world->earned());
			break;
		case M_SET_TERRAIN: {
			Opaque16 heights;
			Opaque16 water;
			get_to_type(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY)(&heights, const_cast<GDExtensionVariantPtr>(args[0]));
			get_to_type(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY)(&water, const_cast<GDExtensionVariantPtr>(args[1]));
			world->set_terrain(float_index_const(&heights, 0), byte_index_const(&water, 0), static_cast<int>(read_number(args[2])), static_cast<float>(read_number(args[3])), static_cast<float>(read_number(args[4])));
			float_array_free(&heights);
			byte_array_free(&water);
			break;
		}
		case M_SOLVE:
			world->solve(static_cast<float>(read_number(args[0])), static_cast<float>(read_number(args[1])), static_cast<float>(read_number(args[2])));
			break;
		case M_COST_AT:
			return_float(ret, world->cost_at(static_cast<int>(read_number(args[0])), static_cast<float>(read_number(args[1])), static_cast<float>(read_number(args[2]))));
			break;
		case M_TRACE:
			return_floats(ret, world->trace(static_cast<int>(read_number(args[0])), static_cast<float>(read_number(args[1])), static_cast<float>(read_number(args[2]))));
			break;
		case M_SHOTS:
			return_floats(ret, world->shots());
			break;
		case M_KILLS:
			return_int(ret, world->kills());
			break;
		case M_ADD_TOWER:
			return_int(ret, world->add_tower(read_cone(args), static_cast<float>(read_number(args[8])), static_cast<float>(read_number(args[9])), static_cast<float>(read_number(args[10])), static_cast<int>(read_number(args[11]))));
			break;
		case M_REMOVE_TOWER:
			world->remove_tower(static_cast<int>(read_number(args[0])));
			break;
		case M_SET_TOWER_AIM:
			world->set_tower_aim(static_cast<int>(read_number(args[0])), static_cast<float>(read_number(args[1])), static_cast<float>(read_number(args[2])), static_cast<float>(read_number(args[3])));
			break;
		case M_TOWER_KILLS:
			return_int(ret, world->tower_kills(static_cast<int>(read_number(args[0]))));
			break;
		case M_VISIBILITY:
			return_bytes(ret, world->visibility_map(read_cone(args)));
			break;
		case M_COVERED:
			return_float(ret, world->covered_length(read_cone(args)));
			break;
		case M_BEST_AIM:
			return_floats(ret, world->best_aim(read_cone(args)));
			break;
		case M_SET_TOWER_STATS:
			world->set_tower_stats(static_cast<int>(read_number(args[0])), read_floats(args[1], static_cast<int>(read_number(args[2]))));
			break;
		case M_TOWER_VISIBILITY:
			return_bytes(ret, world->tower_visibility(static_cast<int>(read_number(args[0]))));
			break;
		case M_TOWER_COVERED:
			return_float(ret, world->tower_covered(static_cast<int>(read_number(args[0]))));
			break;
		case M_TOWER_BEST_AIM:
			return_floats(ret, world->tower_best_aim(static_cast<int>(read_number(args[0]))));
			break;
		case M_FIRES:
			return_floats(ret, world->fires());
			break;
		case M_STONES:
			return_floats(ret, world->stones());
			break;
		case M_STATS_VISIBILITY:
			return_bytes(ret, world->stats_visibility(read_at(args), read_floats(args[6], static_cast<int>(read_number(args[7])))));
			break;
		case M_STATS_COVERED:
			return_float(ret, world->stats_covered(read_at(args), read_floats(args[6], static_cast<int>(read_number(args[7])))));
			break;
		case M_STATS_BEST_AIM:
			return_floats(ret, world->stats_best_aim(read_at(args), read_floats(args[6], static_cast<int>(read_number(args[7])))));
			break;
		case M_STEP:
			world->step(static_cast<float>(read_number(args[0])));
			return_floats(ret, world->figures());
			break;
		case M_BOATS:
			return_floats(ret, world->boats());
			break;
		case M_BRIDGES:
			return_floats(ret, world->bridge_state());
			break;
		case M_FORGET_BRIDGES:
			world->forget_bridges();
			break;
		case M_ARRIVED:
			return_int(ret, world->arrived());
			break;
		case M_ACTIVE:
			return_int(ret, world->active());
			break;
		case M_CANDIDATES:
			return_int(ret, world->bridge_candidates());
			break;
	}
	(void)count;
}

// Scripts reach this class through untyped variables, which always use method_call above.
// Godot still requires this entry, so a stray typed call reports an error rather than crashing.
void method_ptrcall(void *, GDExtensionClassInstancePtr, const GDExtensionConstTypePtr *, GDExtensionTypePtr) {
	print_error("PathCore must be called through an untyped variable.", "PathCore must be called through an untyped variable.", "method_ptrcall", "binding.cpp", __LINE__, 0);
}

void add_method(const char *name, Method id, std::vector<GDExtensionVariantType> arg_types, GDExtensionVariantType return_type) {
	// All of this is read once while registering, except the names, which stay alive.
	GDExtensionPropertyInfo *arg_info = new GDExtensionPropertyInfo[arg_types.size() + 1];
	GDExtensionClassMethodArgumentMetadata *arg_meta = new GDExtensionClassMethodArgumentMetadata[arg_types.size() + 1];
	Opaque8 *empty_name = make_name("");
	Opaque8 *empty_string = make_string("");
	for (size_t n = 0; n < arg_types.size(); n++) {
		const char letter[5] = { 'a', 'r', 'g', static_cast<char>('0' + n), 0 };
		arg_info[n] = { arg_types[n], make_name(letter), empty_name, 0, empty_string, 6 };
		arg_meta[n] = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE;
	}
	GDExtensionPropertyInfo return_info = { return_type, make_name("result"), empty_name, 0, empty_string, 6 };
	GDExtensionClassMethodInfo info = {};
	info.name = make_name(name);
	info.method_userdata = reinterpret_cast<void *>(static_cast<intptr_t>(id));
	info.call_func = method_call;
	info.ptrcall_func = method_ptrcall;
	info.method_flags = GDEXTENSION_METHOD_FLAGS_DEFAULT;
	info.has_return_value = return_type != GDEXTENSION_VARIANT_TYPE_NIL;
	info.return_value_info = &return_info;
	info.return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE;
	info.argument_count = static_cast<uint32_t>(arg_types.size());
	info.arguments_info = arg_info;
	info.arguments_metadata = arg_meta;
	register_method(g_library, &g_class_name, &info);
}

GDExtensionObjectPtr create_instance(void *, GDExtensionBool) {
	GDExtensionObjectPtr object = construct_object(&g_parent_name);
	object_set_instance(object, &g_class_name, new World());
	return object;
}

void free_instance(void *, GDExtensionClassInstancePtr instance) {
	delete static_cast<World *>(instance);
}

GDExtensionClassCallVirtual get_virtual(void *, GDExtensionConstStringNamePtr, uint32_t) {
	return nullptr;
}

void initialize(void *, GDExtensionInitializationLevel level) {
	if (level != GDEXTENSION_INITIALIZATION_SCENE) {
		return;
	}
	string_name_new(&g_class_name, "PathCore");
	string_name_new(&g_parent_name, "RefCounted");
	float_array_new = get_constructor(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY, 0);
	float_array_free = get_destructor(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY);
	byte_array_free = get_destructor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
	// 848867239 identifies the signature int resize(int) in Godot's extension_api.json.
	float_array_resize = get_builtin(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY, make_name("resize"), 848867239);
	byte_array_new = get_constructor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, 0);
	byte_array_resize = get_builtin(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, make_name("resize"), 848867239);

	GDExtensionClassCreationInfo6 info = {};
	info.is_exposed = 1;
	info.create_instance_func = create_instance;
	info.free_instance_func = free_instance;
	info.get_virtual_func = get_virtual;
	register_class(g_library, &g_class_name, &g_parent_name, &info);

	const GDExtensionVariantType NIL = GDEXTENSION_VARIANT_TYPE_NIL;
	const GDExtensionVariantType INT = GDEXTENSION_VARIANT_TYPE_INT;
	const GDExtensionVariantType FLOAT = GDEXTENSION_VARIANT_TYPE_FLOAT;
	const GDExtensionVariantType FLOATS = GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT32_ARRAY;
	const GDExtensionVariantType BYTES = GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY;
	add_method("configure", M_CONFIGURE, { FLOAT, FLOAT, FLOAT }, NIL);
	add_method("set_void_level", M_SET_VOID_LEVEL, { FLOAT }, NIL);
	add_method("set_type", M_SET_TYPE, { INT, FLOATS }, NIL);
	add_method("set_active_types", M_SET_ACTIVE_TYPES, { FLOATS, INT }, NIL);
	add_method("set_gates", M_SET_GATES, { FLOATS, INT }, NIL);
	add_method("option_costs", M_OPTION_COSTS, { INT, INT }, FLOATS);
	add_method("via_costs", M_VIA_COSTS, { INT, FLOAT, FLOAT }, FLOATS);
	add_method("add_tunnel", M_ADD_TUNNEL, { FLOAT, FLOAT, FLOAT, FLOAT }, INT);
	add_method("remove_tunnel", M_REMOVE_TUNNEL, { INT }, NIL);
	add_method("begin_wave", M_BEGIN_WAVE, {}, NIL);
	add_method("add_group", M_ADD_GROUP, { INT, FLOAT, FLOAT, INT, FLOAT, FLOAT }, NIL);
	add_method("finish_wave", M_FINISH_WAVE, {}, NIL);
	add_method("take_impacts", M_TAKE_IMPACTS, {}, FLOATS);
	add_method("take_launches", M_TAKE_LAUNCHES, {}, FLOATS);
	add_method("take_deaths", M_TAKE_DEATHS, {}, FLOATS);
	add_method("earned", M_EARNED, {}, FLOAT);
	add_method("set_terrain", M_SET_TERRAIN, { FLOATS, BYTES, INT, FLOAT, FLOAT }, NIL);
	add_method("solve", M_SOLVE, { FLOAT, FLOAT, FLOAT }, NIL);
	add_method("cost_at", M_COST_AT, { INT, FLOAT, FLOAT }, FLOAT);
	add_method("trace", M_TRACE, { INT, FLOAT, FLOAT }, FLOATS);
	add_method("shots", M_SHOTS, {}, FLOATS);
	add_method("kills", M_KILLS, {}, INT);
	add_method("add_tower", M_ADD_TOWER, { FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, INT }, INT);
	add_method("remove_tower", M_REMOVE_TOWER, { INT }, NIL);
	add_method("set_tower_aim", M_SET_TOWER_AIM, { INT, FLOAT, FLOAT, FLOAT }, NIL);
	add_method("tower_kills", M_TOWER_KILLS, { INT }, INT);
	add_method("visibility_map", M_VISIBILITY, { FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOAT }, BYTES);
	add_method("covered_length", M_COVERED, { FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOAT }, FLOAT);
	add_method("best_aim", M_BEST_AIM, { FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOAT }, FLOATS);
	add_method("set_tower_stats", M_SET_TOWER_STATS, { INT, FLOATS, INT }, NIL);
	add_method("tower_visibility", M_TOWER_VISIBILITY, { INT }, BYTES);
	add_method("tower_covered", M_TOWER_COVERED, { INT }, FLOAT);
	add_method("tower_best_aim", M_TOWER_BEST_AIM, { INT }, FLOATS);
	add_method("fires", M_FIRES, {}, FLOATS);
	add_method("stones", M_STONES, {}, FLOATS);
	add_method("stats_visibility", M_STATS_VISIBILITY, { FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOATS, INT }, BYTES);
	add_method("stats_covered", M_STATS_COVERED, { FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOATS, INT }, FLOAT);
	add_method("stats_best_aim", M_STATS_BEST_AIM, { FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOAT, FLOATS, INT }, FLOATS);
	add_method("step", M_STEP, { FLOAT }, FLOATS);
	add_method("boats", M_BOATS, {}, FLOATS);
	add_method("bridges", M_BRIDGES, {}, FLOATS);
	add_method("forget_bridges", M_FORGET_BRIDGES, {}, NIL);
	add_method("arrived", M_ARRIVED, {}, INT);
	add_method("active", M_ACTIVE, {}, INT);
	add_method("bridge_candidates", M_CANDIDATES, {}, INT);
}

void deinitialize(void *, GDExtensionInitializationLevel level) {
	if (level == GDEXTENSION_INITIALIZATION_SCENE) {
		unregister_class(g_library, &g_class_name);
	}
}

} // namespace

extern "C" __declspec(dllexport) GDExtensionBool pathcore_init(GDExtensionInterfaceGetProcAddress get_proc, GDExtensionClassLibraryPtr library, GDExtensionInitialization *init) {
	g_library = library;
	variant_new_copy = reinterpret_cast<GDExtensionInterfaceVariantNewCopy>(get_proc("variant_new_copy"));
	variant_destroy = reinterpret_cast<GDExtensionInterfaceVariantDestroy>(get_proc("variant_destroy"));
	variant_get_type = reinterpret_cast<GDExtensionInterfaceVariantGetType>(get_proc("variant_get_type"));
	get_from_type = reinterpret_cast<GDExtensionInterfaceGetVariantFromTypeConstructor>(get_proc("get_variant_from_type_constructor"));
	get_to_type = reinterpret_cast<GDExtensionInterfaceGetVariantToTypeConstructor>(get_proc("get_variant_to_type_constructor"));
	get_constructor = reinterpret_cast<GDExtensionInterfaceVariantGetPtrConstructor>(get_proc("variant_get_ptr_constructor"));
	get_destructor = reinterpret_cast<GDExtensionInterfaceVariantGetPtrDestructor>(get_proc("variant_get_ptr_destructor"));
	get_builtin = reinterpret_cast<GDExtensionInterfaceVariantGetPtrBuiltinMethod>(get_proc("variant_get_ptr_builtin_method"));
	string_name_new = reinterpret_cast<GDExtensionInterfaceStringNameNewWithUtf8Chars>(get_proc("string_name_new_with_utf8_chars"));
	string_new = reinterpret_cast<GDExtensionInterfaceStringNewWithUtf8Chars>(get_proc("string_new_with_utf8_chars"));
	float_index = reinterpret_cast<GDExtensionInterfacePackedFloat32ArrayOperatorIndex>(get_proc("packed_float32_array_operator_index"));
	float_index_const = reinterpret_cast<GDExtensionInterfacePackedFloat32ArrayOperatorIndexConst>(get_proc("packed_float32_array_operator_index_const"));
	byte_index_const = reinterpret_cast<GDExtensionInterfacePackedByteArrayOperatorIndexConst>(get_proc("packed_byte_array_operator_index_const"));
	byte_index = reinterpret_cast<GDExtensionInterfacePackedByteArrayOperatorIndex>(get_proc("packed_byte_array_operator_index"));
	construct_object = reinterpret_cast<GDExtensionInterfaceClassdbConstructObject3>(get_proc("classdb_construct_object3"));
	object_set_instance = reinterpret_cast<GDExtensionInterfaceObjectSetInstance>(get_proc("object_set_instance"));
	register_class = reinterpret_cast<GDExtensionInterfaceClassdbRegisterExtensionClass6>(get_proc("classdb_register_extension_class6"));
	register_method = reinterpret_cast<GDExtensionInterfaceClassdbRegisterExtensionClassMethod>(get_proc("classdb_register_extension_class_method"));
	unregister_class = reinterpret_cast<GDExtensionInterfaceClassdbUnregisterExtensionClass>(get_proc("classdb_unregister_extension_class"));
	print_error = reinterpret_cast<GDExtensionInterfacePrintErrorWithMessage>(get_proc("print_error_with_message"));
	init->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;
	init->userdata = nullptr;
	init->initialize = initialize;
	init->deinitialize = deinitialize;
	return 1;
}
