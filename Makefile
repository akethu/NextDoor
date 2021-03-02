MKDIR_P = mkdir -p
SINGLEGPU_TEST_BUILD_DIR = ./build/tests/singleGPU
TEST_INCLUDE_DIRS = -Igoogletest/googletest/include/  -Lgoogletest/build/lib/ -Isrc/ -Isrc/apps/ -Isrc/tests
GOOGLE_TEST_MAIN = googletest/googletest/src/gtest_main.cc
ARCH_CODE_FLAGS = -arch=compute_61 -code=sm_61
TEST_LFLAGS = -lcurand -lgtest -lpthread

all: tests
directories: 
	${MKDIR_P} $(SINGLEGPU_TEST_BUILD_DIR)

#**************TESTS********************#
tests: all-singleGPU-tests all-multiGPU-tests

all-singleGPU-tests: directories $(SINGLEGPU_TEST_BUILD_DIR)/deepWalkTest $(SINGLEGPU_TEST_BUILD_DIR)/khopTest $(SINGLEGPU_TEST_BUILD_DIR)/layerTest $(SINGLEGPU_TEST_BUILD_DIR)/multiRWTest $(SINGLEGPU_TEST_BUILD_DIR)/subGraphSamplingTests $(SINGLEGPU_TEST_BUILD_DIR)/mvsSamplingTests 
all-multiGPU-tests: directories deepWalkTest-multiGPU khopTest-multiGPU layerTest-multiGPU multiRWTest-multiGPU subGraphSamplingTests-multiGPU mvsSamplingTests-multiGPU

$(SINGLEGPU_TEST_BUILD_DIR)/khopTest: src/tests/singleGPU/khopTests.cu src/nextdoor.cu src/tests/testBase.h src/check_results.cu 
	nvcc $< $(TEST_INCLUDE_DIRS) $(TEST_LFLAGS) $(GOOGLE_TEST_MAIN) $(ARCH_CODE_FLAGS) -Xcompiler -fopenmp  -maxrregcount=40 -o $@

$(SINGLEGPU_TEST_BUILD_DIR)/deepWalkTest: src/tests/singleGPU/deepWalk.cu src/nextdoor.cu src/tests/testBase.h src/check_results.cu
	nvcc $< $(TEST_INCLUDE_DIRS) $(TEST_LFLAGS) $(GOOGLE_TEST_MAIN) $(ARCH_CODE_FLAGS) -O3 -Xptxas -O3 -Xcompiler -fopenmp -o $@

$(SINGLEGPU_TEST_BUILD_DIR)/uniformRandWalkTest: src/tests/uniformRandWalk.cu src/nextdoor.cu src/tests/testBase.h src/check_results.cu
	nvcc $< $(TEST_INCLUDE_DIRS) $(TEST_LFLAGS) $(GOOGLE_TEST_MAIN) $(ARCH_CODE_FLAGS) -Xcompiler -fopenmp -o $@

$(SINGLEGPU_TEST_BUILD_DIR)/layerTest: src/tests/singleGPU/layerTests.cu src/nextdoor.cu src/tests/testBase.h src/check_results.cu
	nvcc $< $(TEST_INCLUDE_DIRS) $(TEST_LFLAGS) $(GOOGLE_TEST_MAIN) $(ARCH_CODE_FLAGS) -Xcompiler -fopenmp -o $@

$(SINGLEGPU_TEST_BUILD_DIR)/multiRWTest: src/tests/singleGPU/multiRW.cu src/nextdoor.cu src/tests/testBase.h src/check_results.cu
	nvcc $< $(TEST_INCLUDE_DIRS) $(TEST_LFLAGS) $(GOOGLE_TEST_MAIN) $(ARCH_CODE_FLAGS) -Xcompiler -fopenmp -o $@

$(SINGLEGPU_TEST_BUILD_DIR)/subGraphSamplingTests: src/tests/singleGPU/subGraphSamplingTests.cu src/nextdoor.cu src/tests/testBase.h src/check_results.cu
	nvcc $< $(TEST_INCLUDE_DIRS) $(TEST_LFLAGS) $(GOOGLE_TEST_MAIN) $(ARCH_CODE_FLAGS) -Xcompiler -fopenmp -o $@

$(SINGLEGPU_TEST_BUILD_DIR)/mvsSamplingTests: src/tests/singleGPU/mvs.cu src/nextdoor.cu src/tests/testBase.h src/check_results.cu
	nvcc $< $(TEST_INCLUDE_DIRS) $(TEST_LFLAGS) $(GOOGLE_TEST_MAIN) $(ARCH_CODE_FLAGS) -Xcompiler -fopenmp -o $@
########################################

#*************APPS*********************#
clusterGCNSampling: apps/clustergcn.cu src/nextdoor.cu src/nextDoorModule.cu src/main.cu src/check_results.cu
	nvcc $< -IAnyOption/ AnyOption/anyoption.cpp -DPYTHON_3 -I/usr/include/python3.7m/ -Isrc -lcurand -lpthread $(ARCH_CODE_FLAGS) -Xcompiler -fopenmp -o $@

fastgcn_sampling: apps/fastgcn_sampling.cu src/nextdoor.cu src/main.cu 
	nvcc $< -IAnyOption/ AnyOption/anyoption.cpp -Isrc  -lcurand -lpthread  $(ARCH_CODE_FLAGS) -Xcompiler -fopenmp -o $@
#**************************************#

#*************Python Modules*******#
fastgcn_samplingIntegrationPython2: apps/fastgcn_sampling.cu src/nextdoor.cu src/main.cu src/libNextDoor.hpp src/nextDoorModule.cu
	nvcc $< -DPYTHON_2 -IAnyOption/ AnyOption/anyoption.cpp -I/usr/include/python2.7/ -Isrc  -lcurand -lpthread  $(ARCH_CODE_FLAGS) -Xcompiler -fopenmp -o NextDoor.so -shared -lcurand -Xptxas -O3 -Xcompiler -Wall,-fPIC

fastgcn_samplingIntegrationPython3: apps/fastgcn_sampling.cu src/nextdoor.cu src/main.cu src/libNextDoor.hpp src/nextDoorModule.cu
	nvcc $< -DPYTHON_3 -IAnyOption/ AnyOption/anyoption.cpp -I/usr/include/python3.7m/ -Isrc -lcurand -lpthread  $(ARCH_CODE_FLAGS) -Xcompiler -fopenmp -o NextDoor.so -shared -lcurand -Xptxas -O3 -Xcompiler -Wall,-fPIC
####################################

clean:
	rm -rf cpu gpu *.h.gch *.o src/*.h.gch src/*.o src/*.o build/*
