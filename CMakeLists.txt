project(sampling LANGUAGES CUDA)
cmake_minimum_required(VERSION 3.15)

include(CheckLanguage)
check_language(CUDA)

set(CUDA_PATH "/usr/local/cuda")
# GFlags
add_subdirectory(deps/gflags)
include_directories(${PROJECT_BINARY_DIR}/deps/gflags/include)
link_directories(${PROJECT_BINARY_DIR}/deps/gflags/lib)

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fopenmp")

############## BUILD ##############
set(EXTRA_LIBS gflags)

set(CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS} -gencode arch=compute_75,code=sm_75 -rdc=true  -dc -std=c++11  -res-usage   -Xptxas -v ")
if (CMAKE_BUILD_TYPE STREQUAL "Debug")
  message("Debug mode")
  set(CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS} -g -G -Xcompiler   -ggdb  -lnvrt -Woverloaded-virtual")
else()
  set(CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS} -lineinfo -O3 -Xcompiler  -DNDEBUG ")
endif()

SET(CUDA_SEPARABLE_COMPILATION ON)
set(CUDA_VERBOSE_BUILD ON)

include_directories(include)

if(NOT DEFINED CMAKE_CUDA_STANDARD)
    set(CMAKE_CUDA_STANDARD 11)
    set(CMAKE_CUDA_STANDARD_REQUIRED ON)
endif()

file(GLOB SRC
     "./include/*.cuh"
     "./src/*.cu"
)

add_executable(main
    ${SRC}
    ./src/api/bias_static.cu
    )

target_link_libraries(main 
    ${EXTRA_LIBS} 
    ${CUDA_LIBRARIES}  -fopenmp
    #-L.  -L/usr/local/cuda/targets/x86_64-linux/lib  -ldl -lnvrtc  -lcudart -lcuda -lcudadevrt
    # -Wl,-b,binary,include/graph.cuh -fopenmp
    )

target_compile_options(main PRIVATE $<$<COMPILE_LANGUAGE:CUDA>:
                       --generate-line-info
                       --use_fast_math
                       --relocatable-device-code=true
                       >)
                       


