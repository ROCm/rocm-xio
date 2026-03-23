rdma_shared_provider(rocm_ernic rocm_ernic.map
	1 1.0.${PACKAGE_VERSION}
	main.c
	verbs.c
	dv.c
)

publish_headers(infiniband
	rocm_ernic_dv.h
)

rdma_pkg_config("rocm_ernic" "libibverbs"
	"${CMAKE_THREAD_LIBS_INIT}")
