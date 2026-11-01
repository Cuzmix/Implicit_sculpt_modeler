#+build !js
package jobs

import "core:os"

// The number of CPU cores, which sizes the pool when pool_init is given no count.
@(private)
thread_count_hint :: proc() -> int {
	return max(os.get_processor_core_count(), 1)
}
