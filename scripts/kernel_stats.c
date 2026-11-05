/* What a GPU's compiler makes of one compute kernel, without the GPU: scripts/kernel_stats.py
 * builds this against the system's Vulkan loader and runs it on Mesa's RADV driver with no
 * hardware (RADV_FORCE_FAMILY), which compiles for that AMD family as for the real card.
 *
 *     kernel_stats KERNEL.spv [ID=VALUE ...]
 *
 * Each ID=VALUE sets the 32-bit specialization constant ID. It prints the driver's statistics
 * (VK_KHR_pipeline_executable_properties) as one line of name=value pairs, or a reason and
 * exit status 1. The pipeline layout comes from the kernel's own descriptor decorations, read
 * here from the SPIR-V, so any kernel the renderer makes can be measured as it is. */
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { MAX_ID = 1 << 20, MAX_RESOURCES = 256, MAX_SETS = 8, MAX_CONSTANTS = 16 };

typedef struct {
	uint32_t set, binding, type, count;
} Resource;

/* The ids SPIR-V gives types and variables are dense, so tables indexed by id hold what each is. */
static uint32_t id_op[MAX_ID], id_a[MAX_ID], id_b[MAX_ID];
static uint32_t id_set[MAX_ID], id_binding[MAX_ID], id_decorated[MAX_ID], id_buffer_block[MAX_ID];

enum { OP_TYPE_IMAGE = 25, OP_TYPE_SAMPLER = 26, OP_TYPE_SAMPLED_IMAGE = 27, OP_TYPE_ARRAY = 28,
	OP_TYPE_RUNTIME_ARRAY = 29, OP_TYPE_POINTER = 32, OP_VARIABLE = 59, OP_DECORATE = 71,
	OP_TYPE_ACCEL = 5341 };
enum { DEC_BUFFER_BLOCK = 3, DEC_BINDING = 33, DEC_SET = 34 };
enum { SC_UNIFORM = 2, SC_STORAGE_BUFFER = 12 };

/* Every variable decorated with a set and a binding, as the Vulkan descriptor type it takes. */
static int reflect(const uint32_t *words, size_t count, Resource *out) {
	int n = 0;
	for (size_t i = 5; i < count;) {
		uint32_t length = words[i] >> 16, op = words[i] & 0xffff;
		const uint32_t *a = words + i + 1;
		if (length == 0) break;
		if (op == OP_DECORATE && a[0] < MAX_ID) {
			if (a[1] == DEC_SET) { id_set[a[0]] = a[2]; id_decorated[a[0]] |= 1; }
			if (a[1] == DEC_BINDING) { id_binding[a[0]] = a[2]; id_decorated[a[0]] |= 2; }
			if (a[1] == DEC_BUFFER_BLOCK) id_buffer_block[a[0]] = 1;
		} else if (op == OP_TYPE_POINTER && a[0] < MAX_ID) {
			id_op[a[0]] = op; id_a[a[0]] = a[1]; id_b[a[0]] = a[2];
		} else if (op == OP_TYPE_IMAGE && a[0] < MAX_ID) {
			id_op[a[0]] = op; id_a[a[0]] = a[6]; /* sampled: 2 for a storage image */
		} else if ((op == OP_TYPE_ARRAY || op == OP_TYPE_RUNTIME_ARRAY) && a[0] < MAX_ID) {
			id_op[a[0]] = op; id_a[a[0]] = a[1];
		} else if ((op == OP_TYPE_SAMPLER || op == OP_TYPE_SAMPLED_IMAGE || op == OP_TYPE_ACCEL) && a[0] < MAX_ID) {
			id_op[a[0]] = op;
		} else if (op == OP_VARIABLE && a[1] < MAX_ID && id_decorated[a[1]] == 3 && n < MAX_RESOURCES) {
			uint32_t storage = a[2], type = id_b[a[0]], array = 1;
			while (id_op[type] == OP_TYPE_ARRAY || id_op[type] == OP_TYPE_RUNTIME_ARRAY) {
				/* A runtime array is bound with as many as the renderer's arrays hold at most. */
				array = id_op[type] == OP_TYPE_RUNTIME_ARRAY ? 256 : array;
				type = id_a[type];
			}
			uint32_t kind;
			switch (id_op[type]) {
			case OP_TYPE_SAMPLED_IMAGE: kind = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER; break;
			case OP_TYPE_SAMPLER: kind = VK_DESCRIPTOR_TYPE_SAMPLER; break;
			case OP_TYPE_IMAGE: kind = id_a[type] == 2 ? VK_DESCRIPTOR_TYPE_STORAGE_IMAGE : VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE; break;
			case OP_TYPE_ACCEL: kind = VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR; break;
			default:
				kind = storage == SC_STORAGE_BUFFER || id_buffer_block[type] ? VK_DESCRIPTOR_TYPE_STORAGE_BUFFER : VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
			}
			out[n++] = (Resource){id_set[a[1]], id_binding[a[1]], kind, array};
		}
		i += length;
	}
	return n;
}

static int fail(const char *what, VkResult r) {
	printf("%s failed (%d)\n", what, (int)r);
	return 1;
}

int main(int argc, char **argv) {
	if (argc < 2) {
		printf("usage: kernel_stats KERNEL.spv [ID=VALUE ...]\n");
		return 1;
	}
	FILE *f = fopen(argv[1], "rb");
	if (!f) {
		printf("cannot read %s\n", argv[1]);
		return 1;
	}
	fseek(f, 0, SEEK_END);
	long size = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint32_t *code = malloc((size_t)size);
	if (!code || fread(code, 1, (size_t)size, f) != (size_t)size) {
		printf("cannot read %s\n", argv[1]);
		return 1;
	}
	fclose(f);

	VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO};
	app.apiVersion = VK_API_VERSION_1_3;
	VkInstanceCreateInfo instance_info = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
	instance_info.pApplicationInfo = &app;
	VkInstance instance;
	VkResult r = vkCreateInstance(&instance_info, NULL, &instance);
	if (r) return fail("vkCreateInstance", r);
	uint32_t devices = 1;
	VkPhysicalDevice physical;
	r = vkEnumeratePhysicalDevices(instance, &devices, &physical);
	if ((r && r != VK_INCOMPLETE) || devices == 0) return fail("finding a device", r);

	/* The features the renderer's kernels use, ray queries and texture arrays included. */
	VkPhysicalDevicePipelineExecutablePropertiesFeaturesKHR executables = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PIPELINE_EXECUTABLE_PROPERTIES_FEATURES_KHR};
	executables.pipelineExecutableInfo = VK_TRUE;
	VkPhysicalDeviceRayQueryFeaturesKHR ray_query = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_RAY_QUERY_FEATURES_KHR, &executables};
	ray_query.rayQuery = VK_TRUE;
	VkPhysicalDeviceAccelerationStructureFeaturesKHR accel = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR, &ray_query};
	accel.accelerationStructure = VK_TRUE;
	VkPhysicalDeviceVulkan12Features v12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &accel};
	v12.bufferDeviceAddress = VK_TRUE;
	v12.descriptorIndexing = VK_TRUE;
	v12.runtimeDescriptorArray = VK_TRUE;
	v12.shaderSampledImageArrayNonUniformIndexing = VK_TRUE;
	v12.descriptorBindingVariableDescriptorCount = VK_TRUE;
	v12.descriptorBindingPartiallyBound = VK_TRUE;
	VkPhysicalDeviceFeatures2 features = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v12};
	const char *extensions[] = {"VK_KHR_pipeline_executable_properties", "VK_KHR_ray_query",
		"VK_KHR_acceleration_structure", "VK_KHR_deferred_host_operations"};
	float priority = 1;
	VkDeviceQueueCreateInfo queue = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
	queue.queueCount = 1;
	queue.pQueuePriorities = &priority;
	VkDeviceCreateInfo device_info = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &features};
	device_info.queueCreateInfoCount = 1;
	device_info.pQueueCreateInfos = &queue;
	device_info.enabledExtensionCount = 4;
	device_info.ppEnabledExtensionNames = extensions;
	VkDevice device;
	r = vkCreateDevice(physical, &device_info, NULL, &device);
	if (r) return fail("vkCreateDevice", r);

	VkShaderModuleCreateInfo module_info = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
	module_info.codeSize = (size_t)size;
	module_info.pCode = code;
	VkShaderModule module;
	r = vkCreateShaderModule(device, &module_info, NULL, &module);
	if (r) return fail("vkCreateShaderModule", r);

	static Resource resources[MAX_RESOURCES];
	int count = reflect(code, (size_t)size / 4, resources);
	uint32_t sets = 0;
	for (int i = 0; i < count; i++)
		if (resources[i].set + 1 > sets) sets = resources[i].set + 1;
	if (sets > MAX_SETS) {
		printf("the kernel uses more than %d descriptor sets\n", MAX_SETS);
		return 1;
	}
	VkDescriptorSetLayout set_layouts[MAX_SETS];
	for (uint32_t s = 0; s < sets; s++) {
		VkDescriptorSetLayoutBinding bindings[MAX_RESOURCES];
		uint32_t n = 0;
		for (int i = 0; i < count; i++)
			if (resources[i].set == s)
				bindings[n++] = (VkDescriptorSetLayoutBinding){resources[i].binding, resources[i].type, resources[i].count, VK_SHADER_STAGE_COMPUTE_BIT, NULL};
		VkDescriptorSetLayoutCreateInfo set_info = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
		set_info.bindingCount = n;
		set_info.pBindings = bindings;
		r = vkCreateDescriptorSetLayout(device, &set_info, NULL, &set_layouts[s]);
		if (r) return fail("vkCreateDescriptorSetLayout", r);
	}
	VkPipelineLayoutCreateInfo layout_info = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
	layout_info.setLayoutCount = sets;
	layout_info.pSetLayouts = set_layouts;
	VkPipelineLayout layout;
	r = vkCreatePipelineLayout(device, &layout_info, NULL, &layout);
	if (r) return fail("vkCreatePipelineLayout", r);

	VkSpecializationMapEntry entries[MAX_CONSTANTS];
	uint32_t values[MAX_CONSTANTS];
	uint32_t constants = 0;
	for (int i = 2; i < argc && constants < MAX_CONSTANTS; i++) {
		const char *eq = strchr(argv[i], '=');
		if (!eq) {
			printf("a constant is ID=VALUE, not %s\n", argv[i]);
			return 1;
		}
		entries[constants] = (VkSpecializationMapEntry){(uint32_t)strtoul(argv[i], NULL, 0), 4 * constants, 4};
		values[constants] = (uint32_t)strtoul(eq + 1, NULL, 0);
		constants++;
	}
	VkSpecializationInfo special = {constants, entries, 4 * constants, values};
	VkComputePipelineCreateInfo pipeline_info = {VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
	pipeline_info.flags = VK_PIPELINE_CREATE_CAPTURE_STATISTICS_BIT_KHR;
	pipeline_info.stage = (VkPipelineShaderStageCreateInfo){VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0,
		VK_SHADER_STAGE_COMPUTE_BIT, module, "main", constants ? &special : NULL};
	pipeline_info.layout = layout;
	VkPipeline pipeline;
	r = vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &pipeline_info, NULL, &pipeline);
	if (r) return fail("vkCreateComputePipelines", r);

	PFN_vkGetPipelineExecutablePropertiesKHR get_executables = (PFN_vkGetPipelineExecutablePropertiesKHR)vkGetDeviceProcAddr(device, "vkGetPipelineExecutablePropertiesKHR");
	PFN_vkGetPipelineExecutableStatisticsKHR get_statistics = (PFN_vkGetPipelineExecutableStatisticsKHR)vkGetDeviceProcAddr(device, "vkGetPipelineExecutableStatisticsKHR");
	if (!get_executables || !get_statistics) {
		printf("the driver reports no pipeline statistics\n");
		return 1;
	}
	VkPipelineInfoKHR info = {VK_STRUCTURE_TYPE_PIPELINE_INFO_KHR, NULL, pipeline};
	uint32_t executable_count = 0;
	get_executables(device, &info, &executable_count, NULL);
	for (uint32_t e = 0; e < executable_count; e++) {
		VkPipelineExecutableInfoKHR which = {VK_STRUCTURE_TYPE_PIPELINE_EXECUTABLE_INFO_KHR, NULL, pipeline, e};
		uint32_t stat_count = 0;
		get_statistics(device, &which, &stat_count, NULL);
		VkPipelineExecutableStatisticKHR *stats = calloc(stat_count, sizeof *stats);
		for (uint32_t k = 0; k < stat_count; k++) stats[k].sType = VK_STRUCTURE_TYPE_PIPELINE_EXECUTABLE_STATISTIC_KHR;
		get_statistics(device, &which, &stat_count, stats);
		for (uint32_t k = 0; k < stat_count; k++) {
			if (stats[k].format == VK_PIPELINE_EXECUTABLE_STATISTIC_FORMAT_UINT64_KHR)
				printf("%s=%llu\t", stats[k].name, (unsigned long long)stats[k].value.u64);
			else if (stats[k].format == VK_PIPELINE_EXECUTABLE_STATISTIC_FORMAT_INT64_KHR)
				printf("%s=%lld\t", stats[k].name, (long long)stats[k].value.i64);
		}
		printf("\n");
		free(stats);
	}
	return 0;
}
