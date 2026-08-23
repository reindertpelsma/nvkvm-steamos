import ctypes, sys

lib = ctypes.CDLL("libvulkan.so.1")

class VkApplicationInfo(ctypes.Structure):
    _fields_ = [
        ("sType", ctypes.c_int),
        ("pNext", ctypes.c_void_p),
        ("pApplicationName", ctypes.c_char_p),
        ("applicationVersion", ctypes.c_uint32),
        ("pEngineName", ctypes.c_char_p),
        ("engineVersion", ctypes.c_uint32),
        ("apiVersion", ctypes.c_uint32),
    ]

class VkInstanceCreateInfo(ctypes.Structure):
    _fields_ = [
        ("sType", ctypes.c_int),
        ("pNext", ctypes.c_void_p),
        ("flags", ctypes.c_uint32),
        ("pApplicationInfo", ctypes.POINTER(VkApplicationInfo)),
        ("enabledLayerCount", ctypes.c_uint32),
        ("ppEnabledLayerNames", ctypes.c_void_p),
        ("enabledExtensionCount", ctypes.c_uint32),
        ("ppEnabledExtensionNames", ctypes.c_void_p),
    ]

VK_STRUCTURE_TYPE_APPLICATION_INFO = 0
VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO = 1

app_info = VkApplicationInfo(
    VK_STRUCTURE_TYPE_APPLICATION_INFO, None, b"probe", 1, b"probe", 1,
    (1 << 22) | (4 << 12) | 0  # VK_API_VERSION_1_4 approx
)
create_info = VkInstanceCreateInfo(
    VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, None, 0,
    ctypes.pointer(app_info), 0, None, 0, None
)

instance = ctypes.c_void_p()
vkCreateInstance = lib.vkCreateInstance
vkCreateInstance.restype = ctypes.c_int
rc = vkCreateInstance(ctypes.byref(create_info), None, ctypes.byref(instance))
print("vkCreateInstance rc =", rc, "instance =", instance.value)
if rc != 0:
    sys.exit(0)

vkEnumeratePhysicalDevices = lib.vkEnumeratePhysicalDevices
vkEnumeratePhysicalDevices.restype = ctypes.c_int
count = ctypes.c_uint32(0)
rc2 = vkEnumeratePhysicalDevices(instance, ctypes.byref(count), None)
print("vkEnumeratePhysicalDevices rc =", rc2, "count =", count.value)
