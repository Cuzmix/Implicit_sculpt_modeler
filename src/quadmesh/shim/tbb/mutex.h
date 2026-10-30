// TBB's mutex as the standard one.
#pragma once
#include <mutex>
namespace tbb { using mutex = std::mutex; }
