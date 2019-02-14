#include <iostream>
#include <algorithm>
#include <string>
#include <stdio.h>
#include <vector>
#include <bitset>
#include <unordered_set>
#include <time.h>
#include <sys/time.h>

#include <string.h>
#include <assert.h>

#define LINE_SIZE 1024*1024
//#define USE_FIXED_THREADS
#define MAX_CUDA_THREADS (96*96)
#define THREAD_BLOCK_SIZE 256
#define WARP_SIZE 32
//#define USE_CSR_IN_SHARED
//#define USE_EMBEDDING_IN_SHARED_MEM
//#define USE_EMBEDDING_IN_GLOBAL_MEM
#define USE_EMBEDDING_IN_LOCAL_MEM
//#define SHARED_MEM_NON_COALESCING

#ifdef SHARED_MEM_NON_COALESCING
  #ifndef USE_EMBEDDING_IN_SHARED_MEM
    #error "USE_EMBEDDING_IN_SHARED_MEM must be enabled with SHARED_MEM_NON_COALESCING"
  #endif
#endif
#ifdef USE_EMBEDDING_IN_SHARED_MEM
  #ifdef USE_FIXED_THREADS
    #error "USE_FIXED_THREADS cannot be enabled with USE_EMBEDDING_IN_SHARED_MEM"
  #endif
#endif

//#define USE_CONSTANT_MEM

typedef uint8_t SharedMemElem;

//citeseer.graph
const int N = 3312;
const int N_EDGES = 9074;

//micro.graph
//const int N = 100000;
//const int N_EDGES = 2160312;

class Vertex
{
private:
  int id;
  int label;
  std::vector <int> edges;

public:
  Vertex (int _id, int _label) : label(_label), id (_id)
  {
  }

  int get_id () {return id;}
  int get_label () {return label;}
  void add_edge (int vertexID) {edges.push_back (vertexID);}
  std::vector <int>& get_edges () {return edges;}
  void print (std::ostream& os)
  {
    os << id << " " << label << " ";
    for (auto edge : edges) {
      os << edge << " ";
    }

    os << std::endl;
  }
};

int chars_in_int (int num)
{
  if (num == 0) return sizeof(char);
  return (int)((ceil(log10(num))+1)*sizeof(char));
}

class Graph
{
private:
  std::vector<Vertex> vertices;
  int n_edges;

public:
  Graph (std::vector<Vertex> _vertices, int _n_edges) :
    vertices (_vertices), n_edges(_n_edges)
  {}

  const std::vector<Vertex>& get_vertices () {return vertices;}
  int get_n_edges () {return n_edges;}
};

class CSR
{
public:
  struct Vertex
  {
    int id;
    int label;
    int start_edge_id;
    int end_edge_id;
    __host__ __device__
    Vertex ()
    {
      id = -1;
      label = -1;
      start_edge_id = -1;
      end_edge_id = -1;
    }

    void set_from_graph_vertex (::Vertex& vertex)
    {
      id = vertex.get_id ();
      label = vertex.get_label ();
    }

    void set_start_edge_id (int start) {start_edge_id = start;}
    void set_end_edge_id (int end) {end_edge_id = end;}
  };

  typedef int Edge;

public:
  CSR::Vertex vertices[N];
  CSR::Edge edges[N_EDGES];
  int n_vertices;
  int n_edges;

public:
  CSR (int _n_vertices, int _n_edges)
  {
    n_vertices = _n_vertices;
    n_edges = _n_edges;
  }

  __host__ __device__
  CSR ()
  {
    n_vertices = N;
    n_edges = N_EDGES;
  }

  void print (std::ostream& os)
  {
    for (int i = 0; i < n_vertices; i++) {
      os << vertices[i].id << " " << vertices[i].label << " ";
      for (int edge_iter = vertices[i].start_edge_id;
           edge_iter <= vertices[i].end_edge_id; edge_iter++) {
        os << edges[edge_iter] << " ";
      }
      os << std::endl;
    }
  }

  __host__ __device__
  int get_start_edge_idx (int vertex_id)
  {
    if (!(vertex_id < n_vertices && 0 <= vertex_id)) {
      printf ("vertex_id %d, n_vertices %d\n", vertex_id, n_vertices);
      assert (false);
    }
    return vertices[vertex_id].start_edge_id;
  }

  __host__ __device__
  int get_end_edge_idx (int vertex_id)
  {
    assert (vertex_id < n_vertices && 0 <= vertex_id);
    return vertices[vertex_id].end_edge_id;
  }

  __host__ __device__
  bool has_edge (int u, int v)
  {
    for (int e = get_start_edge_idx (u); e <= get_end_edge_idx (u); e++) {
      if (edges[e] == v) {
        return true;
      }
    }

    return false;
  }

  __host__ __device__
  const CSR::Edge* get_edges () {return &edges[0];}

  __host__ __device__
  const CSR::Vertex* get_vertices () {return &vertices[0];}

  __host__ __device__
  int get_n_vertices () {return n_vertices;}

  __host__ __device__
  void copy_vertices (CSR* src, int start, int end)
  {
    for (int i = start; i < end; i++) {
      vertices[i] = src->get_vertices()[i];
    }
  }

  __host__ __device__
  void copy_edges (CSR* src, int start, int end)
  {
    for (int i = start; i < end; i++) {
      edges[i] = src->get_edges ()[i];
    }
  }

  __host__ __device__
  int get_n_edges () {return n_edges;}
};

#ifdef USE_CONSTANT_MEM
  __constant__ unsigned char csr_constant_buff[sizeof(CSR)];
#endif

void csr_from_graph (CSR* csr, Graph& graph)
{
  int edge_iterator = 0;
  auto graph_vertices = graph.get_vertices ();
  for (int i = 0; i < graph_vertices.size (); i++) {
    ::Vertex& vertex = graph_vertices[i];
    csr->vertices[i].set_from_graph_vertex (graph_vertices[i]);
    csr->vertices[i].set_start_edge_id (edge_iterator);
    for (auto edge : vertex.get_edges ()) {
      csr->edges[edge_iterator] = edge;
      edge_iterator++;
    }

    csr->vertices[i].set_end_edge_id (edge_iterator-1);
  }
}

//template <size_t N> using VertexEmbedding = std::bitset<N>;

#define CVT_TO_NEXT_MULTIPLE(n,k) ((n) %(k) ==0 ? (n) : ((n)/(k)+1)*(k))
class BitVectorVertexEmbedding
{
private:
#ifdef USE_EMBEDDING_IN_SHARED_MEM
  unsigned char array[CVT_TO_NEXT_MULTIPLE(N/8, 32*sizeof(SharedMemElem))];
#else
  unsigned char array[(N/8)];
#endif

public:
  __device__ __host__
  BitVectorVertexEmbedding ()
  {
    //array = new unsigned char[convert_to_bytes_multiple(N)/8];
    assert (array != nullptr);
    reset ();
    assert (all_false () == true);
  }

  __host__ __device__
  size_t convert_to_bytes_multiple (size_t n)
  {
    return (n/8)*8;
  }

  __host__ __device__
  BitVectorVertexEmbedding (const BitVectorVertexEmbedding& embedding)
  {
    //array = new unsigned char[convert_to_bytes_multiple(N)/8];
    for (int i = 0; i <  convert_to_bytes_multiple(N)/8; i++) {
      array[i] = embedding.array[i];
    }
  }

  __host__ __device__
  void set (int index)
  {
    assert (index >= 0 and index < N);
    array[index/8] = array[index/8] | (1 << (index %8));
  }

  __host__ __device__
  void set ()
  {
    for (int i = 0; i < convert_to_bytes_multiple(N)/8; i++) {
      array[i] = (unsigned char) (~(0UL));
    }
  }

  __host__ __device__
  void reset ()
  {
    for (int i = 0; i < convert_to_bytes_multiple(N)/8; i++) {
      array[i] = 0;
    }
  }

  __host__ __device__
  void reset (int index)
  {
    assert (index >= 0 and index < N);
    array[index/8] = array[index/8] & (~(1UL << (index %8)));
  }

  __host__ __device__
  bool test (int index)
  {
    return (bool) ((array[index/8] >> (index % 8))&1);
  }

  __host__ __device__
  bool all_false ()
  {
    for (int i = 0; i < convert_to_bytes_multiple(N)/8; i++) {
      if (array[i] != 0UL) {
        return false;
      }
    }

    return true;
  }
  
  __host__ __device__
  int get_n_vertices () 
  {
    int n_vertices = 0;
    for (int i = 0; i < N; i++) {
      if (test(i) == true) {
        n_vertices++;
      }
    }
    
    return n_vertices;
  }
  
  __host__ __device__
  ~BitVectorVertexEmbedding ()
  {
    //delete[] array;
  }
};

//typedef BitVectorVertexEmbedding VertexEmbedding;

template <uint32_t size> 
class VectorVertexEmbedding
{
private:
  uint32_t array[size];
  uint32_t filled_size;
  
public:
  __device__ __host__
  VectorVertexEmbedding ()
  {
    filled_size = 0;
  }

  __host__ __device__
  VectorVertexEmbedding (const VectorVertexEmbedding<size>& embedding)
  {
  #if DEBUG
    assert (embedding.get_max_size () <= get_max_size ());
  #endif
    filled_size = 0;
    for (int i = 0; i < embedding.get_n_vertices (); i++) {
      add (embedding.get_vertex (i));
    }
  }
  
  __host__ __device__
  void add (int v)
  {
  #if DEBUG
    if (!(size != 0 and filled_size < size)) {
      printf ("filled_size %d, size %d\n", filled_size, size);
      //assert (size != 0 and filled_size < size);
      assert (false);
    }
  #endif
    
    int pos = 0;
    
    for (int i = 0; i < filled_size; i++) {
      if (array[i] > v) {
        pos = i;
        break;
      }
    }
    
    for (int i = filled_size-1; i >= pos ; i--) {
      array[i+1] = array[i];
    }
    
    array[pos] = v;
    filled_size++;
  }

  __host__ __device__
  void add_last_in_sort_order () 
  {
    int v = array[filled_size-1];
    remove_last ();
    add (v);
  }

  __host__ __device__
  void add_unsorted (int v) 
  {
    array[filled_size++] = v;
  }
  
  __host__ __device__
  void remove (int v)
  {
    printf ("Do not support remove\n");
    assert (false);
  }
  
  __host__ __device__
  bool has_logn (int v)
  {
    int l = 0;
    int r = filled_size-1;
    
    while (l <= r) {
      int m = l+(r-l)/2;
      
      if (array[m] == v)
        return true;
      
      if (array[m] < v)
        l = m + 1;
      else
        r = m - 1;
    }
    
    return false;
  }
  
  __host__ __device__
  bool has (int v)
  {
    for (int i = 0; i < filled_size; i++) {
      if (array[i] == v) {
        return true;
      }
    }
    
    return false;
  }
  
  __host__ __device__
  size_t get_n_vertices () const
  {
    return filled_size;
  }
  
  __host__ __device__
  int get_vertex (int index) const
  {
    return array[index];
  }
  
  __host__ __device__
  int get_last_vertex () const
  {
    return array[filled_size-1];
  }
  
  __host__ __device__
  size_t get_max_size () const
  {
    return size;
  }
  
  __host__ __device__
  void clear ()
  {
    filled_size = 0;
  }
  
  __host__ __device__
  void remove_last () 
  {
    assert (filled_size > 0);
    filled_size--;
  }
  __host__ __device__
  ~VectorVertexEmbedding ()
  {
    //delete[] array;
  }
};

template <uint32_t size>
__host__ __device__
void vector_embedding_from_one_less_size (VectorVertexEmbedding<size>& vec_emb1,
                                          VectorVertexEmbedding<size+1>& vec_emb2)
{
  //TODO: Optimize here, filled_size++ in add is being called several times
  //but can be called only once too  
  for (int i = 0; i < vec_emb1.get_n_vertices (); i++) {
    vec_emb2.add (vec_emb1.get_vertex (i));
  }
}

template <uint32_t size> 
void bitvector_to_vector_embedding (BitVectorVertexEmbedding& bit_emb, 
                                    VectorVertexEmbedding<size>& vec_emb)
{
  for (int u = 0; u < N; u++) {
    if (bit_emb.test(u)) {
      vec_emb.add (u);
    }
  }
}

void print_embedding (BitVectorVertexEmbedding embedding, std::ostream& os);

std::vector<BitVectorVertexEmbedding> get_extensions_bitvector (BitVectorVertexEmbedding& embedding, CSR* csr)
{
  std::vector<BitVectorVertexEmbedding> extensions;

  if (embedding.all_false ()) {
    for (int u = 0; u < N; u++) {
      BitVectorVertexEmbedding extension;
      extension.set(u);
      //print_embedding (extension, std::cout);
      //std::cout << " " << u << std::endl;
      extensions.push_back (extension);
    }
  } else {
    for (int u = 0; u < N; u++) {
      if (embedding.test(u)) {
        for (int e = csr->get_start_edge_idx(u); e <= csr->get_end_edge_idx(u); e++) {
          int v = csr->get_edges () [e];
          if (embedding.test (v) == false) {
            BitVectorVertexEmbedding extension = BitVectorVertexEmbedding(embedding);
            extension.set(v);
            extensions.push_back(extension);
          }
        }
      }
    }
  }

  return extensions;
}

template <uint32_t size>
std::vector<VectorVertexEmbedding<size+1>> get_extensions_vector (VectorVertexEmbedding<size>& embedding, CSR* csr)
{
  std::vector<VectorVertexEmbedding<size+1>> extensions;

  if (embedding.get_n_vertices () == 0) {
    for (int u = 0; u < N; u++) {
      VectorVertexEmbedding<size+1> extension;
      extension.add(u);
      //print_embedding (extension, std::cout);
      //std::cout << " " << u << std::endl;
      extensions.push_back (extension);
    }
  } else {
    for (int i = 0; i < embedding.get_n_vertices (); i++) {
      int u = embedding.get_vertex (i);
      for (int e = csr->get_start_edge_idx(u); e <= csr->get_end_edge_idx(u); e++) {
        int v = csr->get_edges () [e];
        if (embedding.has (v) == false) {
          VectorVertexEmbedding<size+1> extension;
          vector_embedding_from_one_less_size (embedding, extension);
          extension.add(v);
          extensions.push_back(extension);
        }
      }
    }
  }

  return extensions;
}

std::vector<BitVectorVertexEmbedding> get_initial_embedding_bitvector (CSR* csr)
{
  BitVectorVertexEmbedding embedding;
  std::vector <BitVectorVertexEmbedding> embeddings;

  embeddings.push_back (embedding);

  return embeddings;
}

std::vector<VectorVertexEmbedding<0>> get_initial_embedding_vector (CSR* csr)
{
  VectorVertexEmbedding<0> embedding;
  std::vector <VectorVertexEmbedding<0>> embeddings;

  embeddings.push_back (embedding);

  return embeddings;
}

bool (*filter) (CSR* csr, BitVectorVertexEmbedding& embedding);
void (*process) (std::vector<BitVectorVertexEmbedding>& output, BitVectorVertexEmbedding& embedding);

__host__ __device__
bool clique_filter (CSR* csr, BitVectorVertexEmbedding* embedding)
{
  for (int u = 0; u < N; u++) {
    if (embedding->test(u)) {
      for (int v = 0; v < N; v++) {
        if (u != v and embedding->test(v)) {
          if (!csr->has_edge (u, v)) {
            return false;
          }
        }
      }
    }
  }

  return true;
}


template <uint32_t size>
__host__ __device__
bool clique_filter_vector (CSR* csr, VectorVertexEmbedding<size>* embedding)
{
  for (int i = 0; i < embedding->get_n_vertices (); i++) {
    int u = embedding->get_vertex (i);
    for (int j = 0; j < embedding->get_n_vertices (); j++) {
      int v = embedding->get_vertex (j);
      if (u != v and embedding->has (v)) {
        if (!csr->has_edge (u, v)) {
          return false;
        }
      }
    }
  }

  return true;
}

void clique_process_bit_vector (std::vector<BitVectorVertexEmbedding>& output, BitVectorVertexEmbedding& embedding)
{
  output.push_back (embedding);
}

template <uint32_t size>
void clique_process_vector (std::vector<VectorVertexEmbedding<size>>& output, VectorVertexEmbedding<size>& embedding)
{
  output.push_back (embedding);
}

void run_single_step_initial_bitvector (void* input, int n_embeddings, CSR* csr,
                      std::vector<BitVectorVertexEmbedding>& output,
                      std::vector<BitVectorVertexEmbedding>& next_step)
{
  BitVectorVertexEmbedding* embeddings = (BitVectorVertexEmbedding*)input;

  for (int i = 0; i < n_embeddings; i++) {
    BitVectorVertexEmbedding embedding = embeddings[i];
    std::vector<BitVectorVertexEmbedding> extensions = get_extensions_bitvector (embedding, csr);

    for (auto extension : extensions) {
      if (clique_filter (csr, &extension)) {
        clique_process_bit_vector (output, extension);
        next_step.push_back (extension);
      }
    }
  }
}

void run_single_step_initial_vector (void* input, int n_embeddings, CSR* csr,
                      std::vector<VectorVertexEmbedding<1>>& output,
                      std::vector<VectorVertexEmbedding<1>>& next_step)
{
  VectorVertexEmbedding<0>* embeddings = (VectorVertexEmbedding<0>*)input;

  for (int i = 0; i < n_embeddings; i++) {
    VectorVertexEmbedding<0> embedding = embeddings[i];
    std::vector<VectorVertexEmbedding<1>> extensions = get_extensions_vector (embedding, csr);
    std::cout << "extensions " << extensions.size () << std::endl;
    for (auto extension : extensions) {
      if (clique_filter_vector (csr, &extension)) {
        clique_process_vector (output, extension);
        next_step.push_back (extension);
      }
    }
  }
}

__device__
void printf_embedding (BitVectorVertexEmbedding* embedding)
{
  printf ("[");
  for (int u = 0; u < N; u++) {
    if (embedding->test(u)) {
      printf ("%d, ", u);
    }
  }

  printf ("]\n");
}

/*__global__
void run_single_step_bitvector_embedding (void* input, int n_embeddings, CSR* csr,
                      void* output_ptr,
                      int* n_output,
                      void* next_step, int* n_next_step,
                      int* n_output_1, int* n_next_step_1)
{
  int id;

#ifdef USE_CSR_IN_SHARED
  __shared__ unsigned char csr_shared_buff[sizeof (CSR)];
  id = threadIdx.x;
  CSR* csr_shared = (CSR*) csr_shared_buff;
  csr_shared->n_vertices = csr->get_n_vertices ();
  csr_shared->n_edges = csr->get_n_edges ();

  int vertices_per_thread = csr->get_n_vertices ()/THREAD_BLOCK_SIZE + 1;
  csr_shared->copy_vertices (csr, id*vertices_per_thread,
                             (id+1)*vertices_per_thread < csr->get_n_vertices () ? (id+1)*vertices_per_thread : csr->get_n_vertices ());

  int edges_per_thread = csr->get_n_edges ()/THREAD_BLOCK_SIZE + 1;
  csr_shared->copy_edges (csr, id*edges_per_thread,
                          (id+1)*edges_per_thread < csr->get_n_edges () ? (id+1)*edges_per_thread : csr->get_n_edges ());
  csr = csr_shared;
  __syncthreads ();
#else
#ifdef USE_CONSTANT_MEM
  csr = (CSR*) csr_constant_buff;
#endif

#endif

  BitVectorVertexEmbedding* embeddings = (BitVectorVertexEmbedding*)input;
  BitVectorVertexEmbedding* new_embeddings = (BitVectorVertexEmbedding*)next_step;
  BitVectorVertexEmbedding* output = ((BitVectorVertexEmbedding*)output_ptr);
#ifdef USE_EMBEDDING_IN_LOCAL_MEM
  unsigned char temp_buffer [sizeof(BitVectorVertexEmbedding)];
#endif
  id = blockIdx.x*blockDim.x + threadIdx.x;
  int start = id, end = id+1;
  //printf ("running id %d\n", id);
#ifdef USE_FIXED_THREADS
  if (n_embeddings >= MAX_CUDA_THREADS) {
    int embeddings_per_thread = n_embeddings/MAX_CUDA_THREADS+1;

    start = id*embeddings_per_thread;
    end = (id+1)*embeddings_per_thread < n_embeddings ? (id+1)*embeddings_per_thread : n_embeddings;
  } else {
    if (id >= n_embeddings)
      return;

    start = id;
    end = id+1;
  }
#else
  if (id >= n_embeddings)
      return;

  start = id;
  end = id+1;
#endif

  int q[1000] = {0};

#ifdef USE_EMBEDDING_IN_SHARED_MEM
  #if 0
    const int shared_mem_size = 49152;
    const int per_thread_shared_mem_size = shared_mem_size/THREAD_BLOCK_SIZE;

    assert (per_thread_shared_mem_size >= sizeof (VertexEmbedding));
    //per_thread_shared_mem_size = sizeof (VertexEmbedding);
    __shared__ SharedMemElem shared_buff[per_thread_shared_mem_size/sizeof (SharedMemElem)];

    SharedMemElem* local_shared_buff = &shared_buff[0];
  #else
    const int shared_mem_size = 49152;
    const int per_thread_shared_mem_size = shared_mem_size/THREAD_BLOCK_SIZE;

    //assert (per_thread_shared_mem_size >= sizeof (VertexEmbedding));
    //per_thread_shared_mem_size = sizeof (VertexEmbedding);
    __shared__ SharedMemElem shared_buff[shared_mem_size/sizeof (SharedMemElem)];

    SharedMemElem* local_shared_buff = &shared_buff[per_thread_shared_mem_size/sizeof(SharedMemElem)*threadIdx.x];
  #endif
#endif

  const int warp_id = threadIdx.x / WARP_SIZE;
  const int lane_id = threadIdx.x % WARP_SIZE;
  for (int i = start; i < end; i++) {
    #ifdef USE_EMBEDDING_IN_SHARED_MEM
      #ifdef SHARED_MEM_NON_COALESCING
        memcpy (local_shared_buff, &embeddings[i], sizeof(BitVectorVertexEmbedding));

        BitVectorVertexEmbedding* embedding = (BitVectorVertexEmbedding*) local_shared_buff;
      #else
        const int thread_block_size = WARP_SIZE;
        const int last_emb = WARP_SIZE*(warp_id+1);
        if (blockIdx.x*blockDim.x + (warp_id+1)*WARP_SIZE > n_embeddings) {
          assert (false);
          //thread_block_size = n_embeddings - blockIdx.x*blockDim.x -
          //                    warp_id*WARP_SIZE;
          //last_emb = warp_id*WARP_SIZE + thread_block_size;
        }

        for (int emb = WARP_SIZE*warp_id; emb < last_emb; emb++) {
          SharedMemElem* embedding_buff = (SharedMemElem*) &embeddings[emb+blockIdx.x*blockDim.x];

          for (int j = 0; j < sizeof (BitVectorVertexEmbedding)/sizeof (SharedMemElem);
               j += thread_block_size) {
            int idx = per_thread_shared_mem_size/sizeof(SharedMemElem)*emb;
            if (true or j + lane_id  < sizeof (BitVectorVertexEmbedding)/sizeof (SharedMemElem)) { //TODO: Remove this if by doing padding with VertexEmbedding
              shared_buff[idx + j + lane_id] = embedding_buff[j + lane_id];
            }
          }
        }

        BitVectorVertexEmbedding* embedding = (BitVectorVertexEmbedding*) local_shared_buff;
      #endif
      //embedding = &embeddings[i];
    #elif defined(USE_EMBEDDING_IN_LOCAL_MEM)
      //memcpy (&temp[0], &embeddings[i], sizeof (VertexEmbedding));
      memcpy (&temp_buffer[0], &embeddings[i], sizeof(BitVectorVertexEmbedding));
      BitVectorVertexEmbedding* embedding = (BitVectorVertexEmbedding*)&temp_buffer[0];
      //VertexEmbedding* embedding = &embeddings[i];
    #elif defined(USE_EMBEDDING_IN_GLOBAL_MEM)
      BitVectorVertexEmbedding* embedding = &embeddings[i];
    #else
      #error "None of USE_EMBEDDING_IN_*_MEM option defined"
    #endif

  #if 1
    typedef uint32_t VertexEmbeddingChange;
    const uint32_t max_changes = 32; //max changes per warp
    //__shared__ int32_t shared_mem [max_changes*THREAD_BLOCK_SIZE/WARP_SIZE+THREAD_BLOCK_SIZE/WARP_SIZE+1];
    __shared__ VertexEmbeddingChange changes[max_changes*THREAD_BLOCK_SIZE/WARP_SIZE];
    __shared__ uint32_t changed_thread_ids[max_changes*THREAD_BLOCK_SIZE/WARP_SIZE];
    //For each warp record new embeddings (or changes) using atomic operations
    __shared__ int32_t n_extensions[THREAD_BLOCK_SIZE/WARP_SIZE];
    n_extensions[warp_id] = 0;
    __shared__ uint32_t prev_n_outputs [THREAD_BLOCK_SIZE/WARP_SIZE];
    __shared__ uint32_t prev_n_next_steps [THREAD_BLOCK_SIZE/WARP_SIZE];
    
    const uint32_t mask = ~0U;
    for (int u = 0; u < N; u++) {
      int e = csr->get_start_edge_idx(u);
      
      while (true) {
        
        int predicate = 1;
        //n_extensions[warp_id] = 0;

        if (e <= csr->get_end_edge_idx(u)) {
          int v = csr->get_edges () [e];
          if (embedding->test(u) and embedding->test (v) == false) {
            BitVectorVertexEmbedding* extension = embedding;
            extension->set(v);
            if (clique_filter (csr, extension)) {
              int prev_n_extensions = atomicAdd (&n_extensions[warp_id], 1);
              changes[warp_id*max_changes+prev_n_extensions] = v;
              changed_thread_ids[warp_id*max_changes+prev_n_extensions] = id;
              //memcpy (&output[atomicAdd(n_output,1)], extension, sizeof (VertexEmbedding));
              //memcpy (&new_embeddings[atomicAdd(n_next_step,1)], extension, sizeof (VertexEmbedding));
            }

            extension->reset(v);
          }

          e++;

          if (e > csr->get_end_edge_idx(u)) {
            predicate = 0;
          }
        } else {
          predicate = 0;
        }

        int32_t n_changes = n_extensions[warp_id];

        if (n_changes > max_changes)
          assert (false);

        //assert (__activemask () == ~0U);
        uint32_t orig_prev_n_output = 0;
        uint32_t orig_prev_n_next_step = 0;
        
        if (lane_id == 0) {
          if (n_changes > 0) {
            n_extensions[warp_id] = 0;
            orig_prev_n_output = atomicAdd (n_output, n_changes);
            orig_prev_n_next_step = atomicAdd (n_next_step, n_changes);
            //if (warp_id == 2 && (threadIdx.x == 64 || threadIdx.x == 65) && blockIdx.x == 0) {
            //  printf ("prev_n_next_steps[warp_id]: %d\n", prev_n_next_steps[warp_id]);
            //}
          }
        }
        
        //__syncwarp ();
        
        if (n_changes > 0) {
          
          uint32_t prev_n_output = __shfl_sync (__activemask (), orig_prev_n_output, 0);
          uint32_t prev_n_next_step = __shfl_sync (__activemask (), orig_prev_n_next_step, 0);
          
          for (int i = 0; i < n_changes; i++) {
            
            int changes_idx = warp_id*max_changes + i;
            uint32_t expected_thread_id = changed_thread_ids[changes_idx];
            if (expected_thread_id == id) {
              int v = changes[changes_idx];
              BitVectorVertexEmbedding* extension = embedding;
              extension->set (v);
              
              memcpy (&output[prev_n_output + i], extension, 
                      sizeof(BitVectorVertexEmbedding));
              memcpy (&new_embeddings[prev_n_next_step + i], extension,
                      sizeof (BitVectorVertexEmbedding));
              extension->reset (v);
            }
          }
        }

        if (n_extensions[warp_id] != 0) {
          printf ("n_extensions[warp_id] not zero but is %d\n", n_extensions[warp_id]);
        }
        if (!__any_sync (__activemask (), predicate)) {
          break;
        }
        //n_extensions[warp_id] = 0;
      }
    }
  #else
    for (int u = 0; u < N; u++) {
      if (embedding->test(u)) {
        for (int e = csr->get_start_edge_idx(u); e <= csr->get_end_edge_idx(u); e++) {
          int v = csr->get_edges () [e];
          if (embedding->test (v) == false) {
            BitVectorVertexEmbedding* extension = embedding;
            extension->set(v);
            if (clique_filter (csr, extension)) {
              memcpy (&output[atomicAdd(n_output,1)], extension, sizeof (BitVectorVertexEmbedding));
              memcpy (&new_embeddings[atomicAdd(n_next_step,1)], extension, sizeof (BitVectorVertexEmbedding));
            }
            extension->reset(v);
          }
        }
      }
    }
  #endif

  }

  //printf ("embeddings generated [1000, 2000)= %d and [2000, 3000) = %d\n", q[0], q[1]);
  //printf ("embeddings at i = 1500: %d\n", q[2]);
  //for (int i = 100; i < 1000; i++) {
  //  printf ("embeddings at i = %d %d\n", i, q[i]);
  //}
}*/

template <size_t embedding_size> 
__global__
void run_single_step_vectorvertex_embedding (void* input, int n_embeddings, CSR* csr,
                      void* output_ptr,
                      int* n_output,
                      void* next_step, int* n_next_step,
                      int* n_output_1, int* n_next_step_1)
{
  int id;

#ifdef USE_CSR_IN_SHARED
  __shared__ unsigned char csr_shared_buff[sizeof (CSR)];
  id = threadIdx.x;
  CSR* csr_shared = (CSR*) csr_shared_buff;
  csr_shared->n_vertices = csr->get_n_vertices ();
  csr_shared->n_edges = csr->get_n_edges ();

  int vertices_per_thread = csr->get_n_vertices ()/THREAD_BLOCK_SIZE + 1;
  csr_shared->copy_vertices (csr, id*vertices_per_thread,
                             (id+1)*vertices_per_thread < csr->get_n_vertices () ? (id+1)*vertices_per_thread : csr->get_n_vertices ());

  int edges_per_thread = csr->get_n_edges ()/THREAD_BLOCK_SIZE + 1;
  csr_shared->copy_edges (csr, id*edges_per_thread,
                          (id+1)*edges_per_thread < csr->get_n_edges () ? (id+1)*edges_per_thread : csr->get_n_edges ());
  csr = csr_shared;
  __syncthreads ();
#else
#ifdef USE_CONSTANT_MEM
  csr = (CSR*) csr_constant_buff;
#endif

#endif

  VectorVertexEmbedding<embedding_size>* embeddings = (VectorVertexEmbedding<embedding_size>*)input;
  VectorVertexEmbedding<embedding_size+1>* new_embeddings = (VectorVertexEmbedding<embedding_size+1>*)next_step;
  VectorVertexEmbedding<embedding_size+1>* output = (VectorVertexEmbedding<embedding_size+1>*)output_ptr;
#ifdef USE_EMBEDDING_IN_LOCAL_MEM
  unsigned char temp_buffer [sizeof(VectorVertexEmbedding<embedding_size+1>)];
#endif
  id = blockIdx.x*blockDim.x + threadIdx.x;
  int start = id, end = id+1;
  //printf ("running id %d\n", id);
#ifdef USE_FIXED_THREADS
  if (n_embeddings >= MAX_CUDA_THREADS) {
    int embeddings_per_thread = n_embeddings/MAX_CUDA_THREADS+1;

    start = id*embeddings_per_thread;
    end = (id+1)*embeddings_per_thread < n_embeddings ? (id+1)*embeddings_per_thread : n_embeddings;
  } else {
    if (id >= n_embeddings)
      return;

    start = id;
    end = id+1;
  }
#else
  if (id >= n_embeddings)
      return;

  start = id;
  end = id+1;
#endif

  int q[1000] = {0};

#ifdef USE_EMBEDDING_IN_SHARED_MEM
//TODO: Support VectorVertexEmbedding
  #if 0
    const int shared_mem_size = 49152;
    const int per_thread_shared_mem_size = shared_mem_size/THREAD_BLOCK_SIZE;

    assert (per_thread_shared_mem_size >= sizeof (VectorVertexEmbedding<embedding_size>));
    //per_thread_shared_mem_size = sizeof (VertexEmbedding);
    __shared__ SharedMemElem shared_buff[per_thread_shared_mem_size/sizeof (SharedMemElem)];

    SharedMemElem* local_shared_buff = &shared_buff[0];
  #else
    const int shared_mem_size = 49152;
    const int per_thread_shared_mem_size = shared_mem_size/THREAD_BLOCK_SIZE;

    //assert (per_thread_shared_mem_size >= sizeof (VertexEmbedding));
    //per_thread_shared_mem_size = sizeof (VertexEmbedding);
    __shared__ SharedMemElem shared_buff[shared_mem_size/sizeof (SharedMemElem)];

    SharedMemElem* local_shared_buff = &shared_buff[per_thread_shared_mem_size/sizeof(SharedMemElem)*threadIdx.x];
  #endif
#endif

  const int warp_id = threadIdx.x / WARP_SIZE;
  const int lane_id = threadIdx.x % WARP_SIZE;
  for (int i = start; i < end; i++) {
    #ifdef USE_EMBEDDING_IN_SHARED_MEM
    //TODO: Support VectorVertexEmbedding, size+1
      #ifdef SHARED_MEM_NON_COALESCING
        memcpy (local_shared_buff, &embeddings[i], sizeof(VectorVertexEmbedding<embedding_size>));

        VectorVertexEmbedding<embedding_size>* embedding = (VectorVertexEmbedding<embedding_size>*) local_shared_buff;
      #else
        const int thread_block_size = WARP_SIZE;
        const int last_emb = WARP_SIZE*(warp_id+1);
        if (blockIdx.x*blockDim.x + (warp_id+1)*WARP_SIZE > n_embeddings) {
          assert (false);
          /*thread_block_size = n_embeddings - blockIdx.x*blockDim.x -
                              warp_id*WARP_SIZE;
          last_emb = warp_id*WARP_SIZE + thread_block_size;*/
        }

        for (int emb = WARP_SIZE*warp_id; emb < last_emb; emb++) {
          SharedMemElem* embedding_buff = (SharedMemElem*) &embeddings[emb+blockIdx.x*blockDim.x];

          for (int j = 0; j < sizeof (VectorVertexEmbedding<embedding_size>)/sizeof (SharedMemElem);
               j += thread_block_size) {
            int idx = per_thread_shared_mem_size/sizeof(SharedMemElem)*emb;
            if (true or j + lane_id  < sizeof (VectorVertexEmbedding<embedding_size>)/sizeof (SharedMemElem)) { //TODO: Remove this if by doing padding with VertexEmbedding
              shared_buff[idx + j + lane_id] = embedding_buff[j + lane_id];
            }
          }
        }

        VectorVertexEmbedding<embedding_size>* embedding = (VectorVertexEmbedding<embedding_size>*) local_shared_buff;
      #endif
      //embedding = &embeddings[i];
    #elif defined(USE_EMBEDDING_IN_LOCAL_MEM)
      //memcpy (&temp[0], &embeddings[i], sizeof (VertexEmbedding));
      //memcpy (&temp_buffer[0], &embeddings[i], sizeof(VectorVertexEmbedding<embedding_size>));
      VectorVertexEmbedding<embedding_size+1>* embedding = (VectorVertexEmbedding<embedding_size+1>*)&temp_buffer[0];
      embedding->clear ();
      vector_embedding_from_one_less_size (embeddings[i], *embedding);
      //VertexEmbedding* embedding = &embeddings[i];
    #elif defined(USE_EMBEDDING_IN_GLOBAL_MEM)
    //TODO: Support VectorVertexEmbedding with size + 1, below is wrong
      VectorVertexEmbedding<embedding_size+1>* embedding = &embeddings[i];
    #else
      #error "None of USE_EMBEDDING_IN_*_MEM option defined"
    #endif

  #if 0
  //TODO: Support VectorVertexEmbedding with size + 1.
    typedef uint32_t VertexEmbeddingChange;
    const uint32_t max_changes = 32; //max changes per warp
    //__shared__ int32_t shared_mem [max_changes*THREAD_BLOCK_SIZE/WARP_SIZE+THREAD_BLOCK_SIZE/WARP_SIZE+1];
    __shared__ VertexEmbeddingChange changes[max_changes*THREAD_BLOCK_SIZE/WARP_SIZE];
    __shared__ uint32_t changed_thread_ids[max_changes*THREAD_BLOCK_SIZE/WARP_SIZE];
    //For each warp record new embeddings (or changes) using atomic operations
    __shared__ int32_t n_extensions[THREAD_BLOCK_SIZE/WARP_SIZE];
    n_extensions[warp_id] = 0;
    __shared__ uint32_t prev_n_outputs [THREAD_BLOCK_SIZE/WARP_SIZE];
    __shared__ uint32_t prev_n_next_steps [THREAD_BLOCK_SIZE/WARP_SIZE];
    
    const uint32_t mask = ~0U;
    for (int u = 0; u < N; u++) {
      int e = csr->get_start_edge_idx(u);
      
      while (true) {
        
        int predicate = 1;
        //n_extensions[warp_id] = 0;

        if (e <= csr->get_end_edge_idx(u)) {
          int v = csr->get_edges () [e];
          if (embedding->test(u) and embedding->test (v) == false) {
            BitVectorVertexEmbedding* extension = embedding;
            extension->set(v);
            if (clique_filter (csr, extension)) {
              int prev_n_extensions = atomicAdd (&n_extensions[warp_id], 1);
              changes[warp_id*max_changes+prev_n_extensions] = v;
              changed_thread_ids[warp_id*max_changes+prev_n_extensions] = id;
              //memcpy (&output[atomicAdd(n_output,1)], extension, sizeof (VertexEmbedding));
              //memcpy (&new_embeddings[atomicAdd(n_next_step,1)], extension, sizeof (VertexEmbedding));
            }

            extension->reset(v);
          }

          e++;

          if (e > csr->get_end_edge_idx(u)) {
            predicate = 0;
          }
        } else {
          predicate = 0;
        }

        int32_t n_changes = n_extensions[warp_id];

        if (n_changes > max_changes)
          assert (false);

        //assert (__activemask () == ~0U);
        uint32_t orig_prev_n_output = 0;
        uint32_t orig_prev_n_next_step = 0;
        
        if (lane_id == 0) {
          if (n_changes > 0) {
            n_extensions[warp_id] = 0;
            orig_prev_n_output = atomicAdd (n_output, n_changes);
            orig_prev_n_next_step = atomicAdd (n_next_step, n_changes);
            //if (warp_id == 2 && (threadIdx.x == 64 || threadIdx.x == 65) && blockIdx.x == 0) {
            //  printf ("prev_n_next_steps[warp_id]: %d\n", prev_n_next_steps[warp_id]);
            //}
          }
        }
        
        //__syncwarp ();
        
        if (n_changes > 0) {
          
          uint32_t prev_n_output = __shfl_sync (__activemask (), orig_prev_n_output, 0);
          uint32_t prev_n_next_step = __shfl_sync (__activemask (), orig_prev_n_next_step, 0);
          
          for (int i = 0; i < n_changes; i++) {
            
            int changes_idx = warp_id*max_changes + i;
            uint32_t expected_thread_id = changed_thread_ids[changes_idx];
            if (expected_thread_id == id) {
              int v = changes[changes_idx];
              BitVectorVertexEmbedding* extension = embedding;
              extension->set (v);
              
              memcpy (&output[prev_n_output + i], extension, 
                      sizeof(BitVectorVertexEmbedding));
              memcpy (&new_embeddings[prev_n_next_step + i], extension,
                      sizeof (BitVectorVertexEmbedding));
              extension->reset (v);
            }
          }
        }

        if (n_extensions[warp_id] != 0) {
          printf ("n_extensions[warp_id] not zero but is %d\n", n_extensions[warp_id]);
        }
        if (!__any_sync (__activemask (), predicate)) {
          break;
        }
        //n_extensions[warp_id] = 0;
      }
    }
  #else
    for (int i = 0; i < embedding->get_n_vertices (); i++) {
      int u = embedding->get_vertex (i);
      for (int e = csr->get_start_edge_idx(u); e <= csr->get_end_edge_idx(u); e++) {
        int v = csr->get_edges () [e];
        bool is_canonical = true;
        is_canonical = !(embedding->get_vertex (0) > v);
        /*if (is_canonical) {
          bool found_neighbor = false;
          for (int j = 0; j < embedding->get_n_vertices (); j++) {
            int v_j = embedding->get_vertex (j);
            if (found_neighbor == false && csr->has_edge (v_j, v)) {
              found_neighbor = true;
            } else if (found_neighbor == true && v_j > v) {
              is_canonical = false;
              break;
            }
          }
        }*/
        if (is_canonical && embedding->has (v) == false) {
          VectorVertexEmbedding<embedding_size+1>* extension = embedding;
          extension->add_unsorted (v);
          
          if (clique_filter_vector (csr, extension)) {
            //VectorVertexEmbedding<embedding_size+1> extension = *embedding;
            //extension.add_last_in_sort_order ();
            int o = atomicAdd(n_output,1);
            int n = atomicAdd(n_next_step,1);
            memcpy (&output[o], extension, sizeof (VectorVertexEmbedding<embedding_size+1>));
            memcpy (&new_embeddings[n], extension, sizeof (VectorVertexEmbedding<embedding_size+1>));
            //output[o].add_last_in_sort_order ();
            new_embeddings[n].add_last_in_sort_order ();
          }
          extension->remove_last ();
        }
      }
    }
  #endif

  }

  //printf ("embeddings generated [1000, 2000)= %d and [2000, 3000) = %d\n", q[0], q[1]);
  //printf ("embeddings at i = 1500: %d\n", q[2]);
  //for (int i = 100; i < 1000; i++) {
  //  printf ("embeddings at i = %d %d\n", i, q[i]);
  //}
}

void print_embedding (BitVectorVertexEmbedding embedding, std::ostream& os)
{
  os << "[";
  for (int u = 0; u < N; u++) {
    if (embedding.test(u)) {
      os << u << ", ";
    }
  }
  os << "]";
}

__global__ void print_kernel() {
    printf("Hello from block %d, thread %d\n", blockIdx.x, threadIdx.x);
}

double_t convertTimeValToDouble (struct timeval _time)
{
  return ((double_t)_time.tv_sec) + ((double_t)_time.tv_usec)/1000000.0f;
}

struct timeval getTimeOfDay ()
{
  struct timeval _time;

  if (gettimeofday (&_time, NULL) == -1) {
    fprintf (stderr, "gettimeofday returned -1\n");
    perror ("");
    abort ();
  }

  return _time;
}

enum EmbeddingType {
  VectorVertex,
  BitVector,
};

int main (int argc, char* argv[])
{
  std::vector<Vertex> vertices;
  int n_edges = 0;

  if (argc < 2) {
    std::cout << "Arguments: graph-file" << std::endl;
    return -1;
  }

  char* graph_file = argv[1];
  FILE* fp = fopen (graph_file, "r+");
  if (fp == nullptr) {
    std::cout << "File '" << graph_file << "' not found" << std::endl;
    return 1;
  }

  while (true) {
    char line[LINE_SIZE];
    char num_str[LINE_SIZE];
    size_t line_size;

    if (fgets (line, LINE_SIZE, fp) == nullptr) {
      break;
    }

    int id, label;
    int bytes_read;

    bytes_read = sscanf (line, "%d %d", &id, &label);
    Vertex vertex (id, label);
    char* _line = line + chars_in_int (id) + chars_in_int (label);
    do {
      int num;

      bytes_read = sscanf (_line, "%d", &num);
      if (bytes_read > 0) {
        vertex.add_edge (num);
        _line += chars_in_int (num);
        n_edges++;
      }

    } while (bytes_read > 0);

    vertices.push_back (vertex);
  }

  fclose (fp);

  std::cout << "n_edges "<<n_edges <<std::endl;
  std::cout << "vertices " << vertices.size () << std::endl; 
  Graph graph (vertices, n_edges);

  CSR* csr = new CSR(N, N_EDGES);
  std::cout << "sizeof(CSR)"<< sizeof(CSR)<<std::endl;
  std::cout <<"sizeof(VertexEmbedding)" << sizeof(BitVectorVertexEmbedding) << std::endl;
  csr_from_graph (csr, graph);
  
#ifdef USE_CONSTANT_MEM
  cudaMemcpyToSymbol (csr_constant_buff, csr, sizeof(CSR));
  //~ CSR* csr_constant = (CSR*) &csr_constant_buff[0];
  //~ csr_constant->n_vertices = csr->get_n_vertices ();
  //~ printf ("csr->get_n_vertices () = %d\n", csr->get_n_vertices ());
  //~ csr_constant->n_edges = csr->get_n_edges ();
  //~ csr_constant->copy_vertices (csr, 0, csr->get_n_vertices ());
  //~ csr_constant->copy_edges (csr, 0, csr->get_n_edges ());
#endif

  std::vector<VectorVertexEmbedding<0>> initial_embeddings = get_initial_embedding_vector (csr);
  std::vector<VectorVertexEmbedding<1>> output_1;
  std::vector<VectorVertexEmbedding<2>> output_2;
  std::vector<VectorVertexEmbedding<3>> output_3;
  std::vector<VectorVertexEmbedding<4>> output_4;
  std::vector<VectorVertexEmbedding<5>> output_5;
  std::vector<VectorVertexEmbedding<6>> output_6;
  std::vector<VectorVertexEmbedding<7>> output_7;
  std::vector<VectorVertexEmbedding<8>> output_8;
  void* embeddings;
  //filter = clique_filter;
  //process = clique_process;
  size_t new_embeddings_size = 0;
  int iter = 0;
  {
    std::vector<VectorVertexEmbedding<1>> new_embeddings;
    run_single_step_initial_vector (&initial_embeddings[0], 1, csr, 
                                    output_1, new_embeddings);
    new_embeddings_size = new_embeddings.size ();
    embeddings = malloc (sizeof (VectorVertexEmbedding<1>)*new_embeddings_size);
    for (int i = 0; i < new_embeddings_size; i++) {
      ((VectorVertexEmbedding<1>*)embeddings)[i] = new_embeddings[i];
      int v = ((VectorVertexEmbedding<1>*)embeddings)[i].get_vertex (0);
      assert (v >= 0);
    }
  }

  iter = 1;

  double_t kernelTotalTime = 0.0;
  for (iter; iter < 8 && new_embeddings_size > 0; iter++) {
    std::cout << "iter " << iter << " embeddings " << new_embeddings_size << std::endl;
    size_t global_mem_size = 10*1024*1024*1024UL;
    char* global_mem_ptr = new char[global_mem_size];
  #ifdef DEBUG
    memset (global_mem_ptr, 0, global_mem_size);
  #endif
    int n_embeddings = new_embeddings_size;
    //n_embeddings = (n_embeddings/THREAD_BLOCK_SIZE)*THREAD_BLOCK_SIZE;
    std::cout << "iter " << iter << " n_embeddings " << n_embeddings << std::endl;
    size_t embedding_size = 0;
    size_t new_embedding_size = 0;
    switch (iter) {
      case 1: {
        embedding_size = sizeof (VectorVertexEmbedding<1>);
        new_embedding_size = sizeof (VectorVertexEmbedding<2>);
        for (int i = 0; i < n_embeddings; i++) {
          ((VectorVertexEmbedding<1>*)global_mem_ptr)[i] = ((VectorVertexEmbedding<1>*) embeddings)[i];
          int v = ((VectorVertexEmbedding<1>*)global_mem_ptr)[i].get_vertex (0);
          assert (v >= 0);
        }
        break;
      }      
      case 2: {
        embedding_size = sizeof (VectorVertexEmbedding<2>);
        new_embedding_size = sizeof (VectorVertexEmbedding<3>);
        for (int i = 0; i < n_embeddings; i++) {
          ((VectorVertexEmbedding<2>*)global_mem_ptr)[i] = ((VectorVertexEmbedding<2>*)embeddings)[i];
        }
        break;
      }
      
      case 3: {
        embedding_size = sizeof (VectorVertexEmbedding<3>);
        new_embedding_size = sizeof (VectorVertexEmbedding<4>);
        for (int i = 0; i < n_embeddings; i++) {
          ((VectorVertexEmbedding<3>*)global_mem_ptr)[i] = ((VectorVertexEmbedding<3>*)embeddings)[i];
        }
        break;
      }
      
      case 4: {
          embedding_size = sizeof (VectorVertexEmbedding<4>);
          new_embedding_size = sizeof (VectorVertexEmbedding<5>);
          for (int i = 0; i < n_embeddings; i++) {
            ((VectorVertexEmbedding<4>*)global_mem_ptr)[i] = ((VectorVertexEmbedding<4>*)embeddings)[i];
        }
        break;
      }
      case 5: {
        embedding_size = sizeof (VectorVertexEmbedding<5>);
        new_embedding_size = sizeof (VectorVertexEmbedding<6>);
        for (int i = 0; i < n_embeddings; i++) {
          ((VectorVertexEmbedding<5>*)global_mem_ptr)[i] = ((VectorVertexEmbedding<5>*)embeddings)[i];
        }
        break;
      }
      case 6: {
        embedding_size = sizeof (VectorVertexEmbedding<6>);
        new_embedding_size = sizeof (VectorVertexEmbedding<7>);
        for (int i = 0; i < n_embeddings; i++) {
          ((VectorVertexEmbedding<6>*)global_mem_ptr)[i] = ((VectorVertexEmbedding<6>*)embeddings)[i];
        }
        break;
      }
      case 7: {
        embedding_size = sizeof (VectorVertexEmbedding<7>);
        new_embedding_size = sizeof (VectorVertexEmbedding<8>);
        for (int i = 0; i < n_embeddings; i++) {
          ((VectorVertexEmbedding<7>*)global_mem_ptr)[i] = ((VectorVertexEmbedding<7>*)embeddings)[i];
        }
        break;
      }
      case 8: {
        embedding_size = sizeof (VectorVertexEmbedding<8>);
        new_embedding_size = sizeof (VectorVertexEmbedding<9>);
        for (int i = 0; i < n_embeddings; i++) {
          ((VectorVertexEmbedding<8>*)global_mem_ptr)[i] = ((VectorVertexEmbedding<8>*)embeddings)[i];
        }
        break;
      }
    }
    
    //TODO: delete embeddings too because there is a memory leak?
    if (iter > 1) {
      free(embeddings);
    }
    
    void* embeddings_ptr = global_mem_ptr;

    int n_new_embeddings = 0;
    int n_new_embeddings_1 = 0;
    void* new_embeddings_ptr = (char*)embeddings_ptr + (n_embeddings)*(new_embedding_size); //Size of next embedding will be one more
    size_t max_embeddings = 40000000; 
    printf ("new_embedding_size %ld\n", new_embedding_size);
    void* output_ptr = (char*)new_embeddings_ptr + (max_embeddings)*(new_embedding_size);
    int n_output = 0;
    int n_output_1 = 0;
    char* device_embeddings;
    char *device_new_embeddings;
    int* device_n_embeddings;
    int* device_n_embeddings_1;
    char *device_outputs;
    int* device_n_outputs;
    int* device_n_outputs_1;
    CSR* device_csr;
    
    const bool unified_mem = false;
    if (unified_mem == true) {
      //cudaMallocManaged (embeddings_ptr, n_embeddings*embedding_size);
      //device_embeddings = (char*)embeddings_ptr;
      assert(false);
    } else {
      cudaMalloc (&device_embeddings, n_embeddings*embedding_size);
      cudaMemcpy (device_embeddings, embeddings_ptr,
                  n_embeddings*embedding_size, cudaMemcpyHostToDevice);
    }
    cudaMalloc (&device_new_embeddings, max_embeddings*(new_embedding_size));
    cudaMalloc (&device_outputs, max_embeddings*(new_embedding_size));
    cudaMalloc (&device_n_embeddings, sizeof (0));
    cudaMalloc (&device_n_embeddings_1, sizeof (0));
    cudaMalloc (&device_n_outputs, sizeof (0));
    cudaMalloc (&device_n_outputs_1, sizeof (0));
    cudaMalloc (&device_csr, sizeof(CSR));
    
    cudaMemcpy (device_n_embeddings, &n_new_embeddings,
                sizeof (n_new_embeddings), cudaMemcpyHostToDevice);
    cudaMemcpy (device_n_outputs, &n_output, sizeof (n_output),
                cudaMemcpyHostToDevice);

    cudaMemcpy (device_n_embeddings_1, &n_new_embeddings_1,
                sizeof (n_new_embeddings_1), cudaMemcpyHostToDevice);
    cudaMemcpy (device_n_outputs_1, &n_output_1, sizeof (n_output_1),
                cudaMemcpyHostToDevice);

    cudaMemcpy (device_csr, csr, sizeof (CSR), cudaMemcpyHostToDevice);
    
    std::cout << "starting kernel with n_embeddings: " << n_embeddings;
  
    double t1 = convertTimeValToDouble (getTimeOfDay ());
    
#ifdef USE_FIXED_THREADS
    //std::cout << " threads: " << MAX_CUDA_THREADS/THREAD_BLOCK_SIZE << std::endl;
    int thread_blocks = MAX_CUDA_THREADS/THREAD_BLOCK_SIZE;
#else
    int thread_blocks = (n_embeddings%THREAD_BLOCK_SIZE != 0) ? (n_embeddings/THREAD_BLOCK_SIZE+1) : n_embeddings/THREAD_BLOCK_SIZE;
#endif
    std::cout << " threads: " << thread_blocks << std::endl;
    switch (iter) {
      case 1: {
        run_single_step_vectorvertex_embedding<1><<<thread_blocks, THREAD_BLOCK_SIZE>>> (device_embeddings, n_embeddings, device_csr,
                              device_outputs, device_n_outputs,
                              device_new_embeddings, device_n_embeddings,
                              device_n_outputs_1, device_n_embeddings_1);
        break;
      }
      case 2: {
        run_single_step_vectorvertex_embedding<2><<<thread_blocks, THREAD_BLOCK_SIZE>>> (device_embeddings, n_embeddings, device_csr,
                              device_outputs, device_n_outputs,
                              device_new_embeddings, device_n_embeddings,
                              device_n_outputs_1, device_n_embeddings_1);
        break;
      }
      case 3: {
        run_single_step_vectorvertex_embedding<3><<<thread_blocks, THREAD_BLOCK_SIZE>>> (device_embeddings, n_embeddings, device_csr,
                              device_outputs, device_n_outputs,
                              device_new_embeddings, device_n_embeddings,
                              device_n_outputs_1, device_n_embeddings_1);
        break;
      }
      case 4: {
        run_single_step_vectorvertex_embedding<4><<<thread_blocks, THREAD_BLOCK_SIZE>>> (device_embeddings, n_embeddings, device_csr,
                              device_outputs, device_n_outputs,
                              device_new_embeddings, device_n_embeddings,
                              device_n_outputs_1, device_n_embeddings_1);
        break;
      }
      case 5: {
        run_single_step_vectorvertex_embedding<5><<<thread_blocks, THREAD_BLOCK_SIZE>>> (device_embeddings, n_embeddings, device_csr,
                              device_outputs, device_n_outputs,
                              device_new_embeddings, device_n_embeddings,
                              device_n_outputs_1, device_n_embeddings_1);
        break;
      }
      case 6: {
        run_single_step_vectorvertex_embedding<6><<<thread_blocks, THREAD_BLOCK_SIZE>>> (device_embeddings, n_embeddings, device_csr,
                              device_outputs, device_n_outputs,
                              device_new_embeddings, device_n_embeddings,
                              device_n_outputs_1, device_n_embeddings_1);
        break;
      }
      case 7: {
        run_single_step_vectorvertex_embedding<7><<<thread_blocks, THREAD_BLOCK_SIZE>>> (device_embeddings, n_embeddings, device_csr,
                              device_outputs, device_n_outputs,
                              device_new_embeddings, device_n_embeddings,
                              device_n_outputs_1, device_n_embeddings_1);
        break;
      }
      case 8: {
        run_single_step_vectorvertex_embedding<8><<<thread_blocks, THREAD_BLOCK_SIZE>>> (device_embeddings, n_embeddings, device_csr,
                              device_outputs, device_n_outputs,
                              device_new_embeddings, device_n_embeddings,
                              device_n_outputs_1, device_n_embeddings_1);
        break;
      }
    }
    
    cudaDeviceSynchronize ();

    double t2 = convertTimeValToDouble (getTimeOfDay ());

    std::cout << "Execution time " << (t2-t1) << " secs" << std::endl;
    kernelTotalTime += (t2-t1);

    cudaError_t error = cudaGetLastError ();
    if (error != cudaSuccess) {
      const char* error_string = cudaGetErrorString (error);
      std::cout << error_string << std::endl;
    } else {
      std::cout << "Cuda success " << std::endl;
    }

    cudaMemcpy (new_embeddings_ptr, device_new_embeddings, max_embeddings*(new_embedding_size), cudaMemcpyDeviceToHost);
    cudaMemcpy (output_ptr, device_outputs, max_embeddings*(new_embedding_size), cudaMemcpyDeviceToHost);
    cudaMemcpy (&n_new_embeddings, device_n_embeddings, sizeof(0), cudaMemcpyDeviceToHost);
    cudaMemcpy (&n_output, device_n_outputs, sizeof(0), cudaMemcpyDeviceToHost);
    cudaMemcpy (&n_new_embeddings_1, device_n_embeddings_1, sizeof(0), cudaMemcpyDeviceToHost);
    cudaMemcpy (&n_output_1, device_n_outputs_1, sizeof(0), cudaMemcpyDeviceToHost);

    std::cout << "n_new_embeddings "<<n_new_embeddings<<std::endl;
    std::cout << "n_new_embeddings_1 "<<n_new_embeddings_1;
    std::cout << " n_output "<<n_output;
    std::cout << " n_output_1 "<<n_output_1<<std::endl;
    new_embeddings_size = n_new_embeddings;
    switch (iter) {
      case 1: {
        VectorVertexEmbedding<2>* new_embeddings = (VectorVertexEmbedding<2>*)malloc (sizeof (VectorVertexEmbedding<2>)*n_new_embeddings);
        
        for (int i = 0; i < n_new_embeddings; i++) {
          VectorVertexEmbedding<2> embedding = ((VectorVertexEmbedding<2>*)new_embeddings_ptr)[i];
          new_embeddings [i] = embedding;
          #ifdef DEBUG
          if (embedding.get_n_vertices () != (iter + 1)) {
            printf ("embedding has %d vertices\n", embedding.get_n_vertices ());
          }
          #endif
        }
        
        embeddings = &new_embeddings[0];
        for (int i = 0; i < n_output; i++) {
          output_2.push_back (((VectorVertexEmbedding<2>*)output_ptr)[i]);
        }
        
        break;
      }
      
      case 2: {
        VectorVertexEmbedding<3>* new_embeddings = (VectorVertexEmbedding<3>*)malloc (sizeof (VectorVertexEmbedding<3>)*n_new_embeddings);
        
        for (int i = 0; i < n_new_embeddings; i++) {
          VectorVertexEmbedding<3> embedding = ((VectorVertexEmbedding<3>*)new_embeddings_ptr)[i];
          new_embeddings [i] = embedding;
          #ifdef DEBUG
          if (embedding.get_n_vertices () != (iter + 1)) {
            printf ("embedding has %ld vertices\n", embedding.get_n_vertices ());
          }
          #endif
        }
        
        embeddings = &new_embeddings[0];
        for (int i = 0; i < n_output; i++) {
          output_3.push_back (((VectorVertexEmbedding<3>*)output_ptr)[i]);
        }
        break;
      }
      
      case 3: {
        VectorVertexEmbedding<4>* new_embeddings = (VectorVertexEmbedding<4>*)malloc (sizeof (VectorVertexEmbedding<4>)*n_new_embeddings);
        
        for (int i = 0; i < n_new_embeddings; i++) {
          VectorVertexEmbedding<4> embedding = ((VectorVertexEmbedding<4>*)new_embeddings_ptr)[i];
          new_embeddings [i] = embedding;
          #ifdef DEBUG
          if (embedding.get_n_vertices () != (iter + 1)) {
            printf ("embedding has %d vertices\n", embedding.get_n_vertices ());
          }
          #endif
        }
        
        embeddings = &new_embeddings[0];
        for (int i = 0; i < n_output; i++) {
          output_4.push_back (((VectorVertexEmbedding<4>*)output_ptr)[i]);
        }
        break;
      }
      
      case 4: {
        VectorVertexEmbedding<5>* new_embeddings = (VectorVertexEmbedding<5>*)malloc (sizeof (VectorVertexEmbedding<5>)*n_new_embeddings);
        
        for (int i = 0; i < n_new_embeddings; i++) {
          VectorVertexEmbedding<5> embedding = ((VectorVertexEmbedding<5>*)new_embeddings_ptr)[i];
          new_embeddings [i] = embedding;
          #ifdef DEBUG
          if (embedding.get_n_vertices () != (iter + 1)) {
            printf ("embedding has %d vertices\n", embedding.get_n_vertices ());
          }
          #endif
        }
        
        embeddings = &new_embeddings[0];
        for (int i = 0; i < n_output; i++) {
          output_5.push_back (((VectorVertexEmbedding<5>*)output_ptr)[i]);
        }
        break;
      }
      
      case 5: {
        VectorVertexEmbedding<6>* new_embeddings = (VectorVertexEmbedding<6>*)malloc (sizeof (VectorVertexEmbedding<6>)*n_new_embeddings);
        
        for (int i = 0; i < n_new_embeddings; i++) {
          VectorVertexEmbedding<6> embedding = ((VectorVertexEmbedding<6>*)new_embeddings_ptr)[i];
          new_embeddings [i] = embedding;
          #ifdef DEBUG
          if (embedding.get_n_vertices () != (iter + 1)) {
            printf ("embedding has %d vertices\n", embedding.get_n_vertices ());
          }
          #endif
        }
        
        embeddings = &new_embeddings[0];
        for (int i = 0; i < n_output; i++) {
          output_6.push_back (((VectorVertexEmbedding<6>*)output_ptr)[i]);
        }
        break;
      }
      
      case 6: {
        VectorVertexEmbedding<7>* new_embeddings = (VectorVertexEmbedding<7>*)malloc (sizeof (VectorVertexEmbedding<7>)*n_new_embeddings);
        
        for (int i = 0; i < n_new_embeddings; i++) {
          VectorVertexEmbedding<7> embedding = ((VectorVertexEmbedding<7>*)new_embeddings_ptr)[i];
          new_embeddings [i] = embedding;
          #ifdef DEBUG
          if (embedding.get_n_vertices () != (iter + 1)) {
            printf ("embedding has %d vertices\n", embedding.get_n_vertices ());
          }
          #endif
        }
        
        embeddings = &new_embeddings[0];
        for (int i = 0; i < n_output; i++) {
          output_7.push_back (((VectorVertexEmbedding<7>*)output_ptr)[i]);
        }
        break;
      }
      
      case 7: {
        VectorVertexEmbedding<8>* new_embeddings = (VectorVertexEmbedding<8>*)malloc (sizeof(VectorVertexEmbedding<8>)*n_new_embeddings);
        
        for (int i = 0; i < n_new_embeddings; i++) {
          VectorVertexEmbedding<8> embedding = ((VectorVertexEmbedding<8>*)new_embeddings_ptr)[i];
          new_embeddings [i] = embedding;
          #ifdef DEBUG
          if (embedding.get_n_vertices () != (iter + 1)) {
            printf ("embedding has %d vertices\n", embedding.get_n_vertices ());
          }
          #endif
        }
        
        embeddings = &new_embeddings[0];
        for (int i = 0; i < n_output; i++) {
          output_8.push_back (((VectorVertexEmbedding<8>*)output_ptr)[i]);
        }
        break;
      }
    }
    
    //embeddings = new_embeddings;

    cudaFree (device_embeddings);
    cudaFree (device_new_embeddings);
    cudaFree (device_n_embeddings);
    cudaFree (device_outputs);
    cudaFree (device_n_outputs);
    cudaFree (device_csr);
    delete[] global_mem_ptr;
  }

  std::cout << "Number of embeddings found "<< (output_1.size () + output_2.size () + output_3.size () + output_4.size () + output_5.size () + output_6.size () + output_7.size () + output_8.size ()) << std::endl;
  std::cout << "Time spent in execution " << kernelTotalTime << std::endl;
  
  
  /* For BitVectorVertexEmbedding
   for (iter; iter < 10 && embeddings.size () > 0; iter++) {
    std::cout << "iter " << iter << " embeddings " << embeddings.size () << std::endl;
    size_t global_mem_size = 3*1024*1024*1024UL;
    char* global_mem_ptr = new char[global_mem_size];
  #ifdef DEBUG
    memset (global_mem_ptr, 0, global_mem_size);
  #endif
    int n_embeddings = embeddings.size ();
    //n_embeddings = (n_embeddings/THREAD_BLOCK_SIZE)*THREAD_BLOCK_SIZE;
    std::cout << "iter " << iter << " n_embeddings " << n_embeddings << std::endl;
  
    for (int i = 0; i < n_embeddings; i++) {
      ((BitVectorVertexEmbedding*)global_mem_ptr)[i] = embeddings[i];
    }
    void* embeddings_ptr = global_mem_ptr;

    int n_new_embeddings = 0;
    int n_new_embeddings_1 = 0;
    void* new_embeddings_ptr = (char*)embeddings_ptr + (n_embeddings)*sizeof(BitVectorVertexEmbedding);
    int max_embeddings = 1000000;
    void* output_ptr = (char*)new_embeddings_ptr + (max_embeddings)*sizeof(BitVectorVertexEmbedding);
    int n_output = 0;
    int n_output_1 = 0;
    char* device_embeddings;
    char *device_new_embeddings;
    int* device_n_embeddings;
    int* device_n_embeddings_1;
    char *device_outputs;
    int* device_n_outputs;
    int* device_n_outputs_1;
    CSR* device_csr;

    cudaMalloc (&device_embeddings, n_embeddings*sizeof(BitVectorVertexEmbedding));
    cudaMemcpy (device_embeddings, embeddings_ptr,
                n_embeddings*sizeof(BitVectorVertexEmbedding),
                cudaMemcpyHostToDevice);
    cudaMalloc (&device_new_embeddings, max_embeddings*sizeof (BitVectorVertexEmbedding));
    cudaMalloc (&device_outputs, max_embeddings*sizeof (BitVectorVertexEmbedding));
    cudaMalloc (&device_n_embeddings, sizeof (0));
    cudaMalloc (&device_n_embeddings_1, sizeof (0));
    cudaMalloc (&device_n_outputs, sizeof (0));
    cudaMalloc (&device_n_outputs_1, sizeof (0));
    cudaMalloc (&device_csr, sizeof(CSR));

    cudaMemcpy (device_n_embeddings, &n_new_embeddings,
                sizeof (n_new_embeddings), cudaMemcpyHostToDevice);
    cudaMemcpy (device_n_outputs, &n_output, sizeof (n_output),
                cudaMemcpyHostToDevice);

    cudaMemcpy (device_n_embeddings_1, &n_new_embeddings_1,
                sizeof (n_new_embeddings_1), cudaMemcpyHostToDevice);
    cudaMemcpy (device_n_outputs_1, &n_output_1, sizeof (n_output_1),
                cudaMemcpyHostToDevice);

    cudaMemcpy (device_csr, csr, sizeof (CSR), cudaMemcpyHostToDevice);

    std::cout << "starting kernel with n_embeddings: " << n_embeddings;

    double t1 = convertTimeValToDouble (getTimeOfDay ());
#ifdef USE_FIXED_THREADS
    std::cout << " threads: " << MAX_CUDA_THREADS/THREAD_BLOCK_SIZE << std::endl;
      run_single_step_bitvector_embedding<<<MAX_CUDA_THREADS/THREAD_BLOCK_SIZE,THREAD_BLOCK_SIZE>>> (device_embeddings, n_embeddings, device_csr,
                              device_outputs, device_n_outputs,
                              device_new_embeddings, device_n_embeddings,
                              device_n_outputs_1, device_n_embeddings_1);
#else
    int thread_blocks = (n_embeddings%THREAD_BLOCK_SIZE != 0) ? (n_embeddings/THREAD_BLOCK_SIZE+1) : n_embeddings/THREAD_BLOCK_SIZE;
    std::cout << " threads: " << n_embeddings/THREAD_BLOCK_SIZE << std::endl;
    run_single_step_bitvector_embedding<<<thread_blocks, THREAD_BLOCK_SIZE>>> (device_embeddings, n_embeddings, device_csr,
                              device_outputs, device_n_outputs,
                              device_new_embeddings, device_n_embeddings,
                              device_n_outputs_1, device_n_embeddings_1);
#endif

    cudaDeviceSynchronize ();

    double t2 = convertTimeValToDouble (getTimeOfDay ());

    std::cout << "Execution time " << (t2-t1) << " secs" << std::endl;
    kernelTotalTime += (t2-t1);

    cudaError_t error = cudaGetLastError ();
    if (error != cudaSuccess) {
      const char* error_string = cudaGetErrorString (error);
      std::cout << error_string << std::endl;
    } else {
      std::cout << "Cuda success " << std::endl;
    }

    cudaMemcpy (new_embeddings_ptr, device_new_embeddings, max_embeddings*sizeof(BitVectorVertexEmbedding), cudaMemcpyDeviceToHost);
    cudaMemcpy (output_ptr, device_outputs, max_embeddings*sizeof(BitVectorVertexEmbedding), cudaMemcpyDeviceToHost);
    cudaMemcpy (&n_new_embeddings, device_n_embeddings, sizeof(0), cudaMemcpyDeviceToHost);
    cudaMemcpy (&n_output, device_n_outputs, sizeof(0), cudaMemcpyDeviceToHost);
    cudaMemcpy (&n_new_embeddings_1, device_n_embeddings_1, sizeof(0), cudaMemcpyDeviceToHost);
    cudaMemcpy (&n_output_1, device_n_outputs_1, sizeof(0), cudaMemcpyDeviceToHost);

    std::cout << "n_new_embeddings "<<n_new_embeddings<<std::endl;
    std::cout << "n_new_embeddings_1 "<<n_new_embeddings_1;
    std::cout << " n_output "<<n_output;
    std::cout << " n_output_1 "<<n_output_1<<std::endl;
    std::vector<BitVectorVertexEmbedding> new_embeddings;
  
    for (int i = 0; i < n_new_embeddings; i++) {
      BitVectorVertexEmbedding embedding = ((BitVectorVertexEmbedding*)new_embeddings_ptr)[i];
      new_embeddings.push_back (embedding);
    #ifdef DEBUG
      if (embedding.get_n_vertices () != (iter + 1)) {
        printf ("embedding has %d vertices\n", embedding.get_n_vertices ());
      }
    #endif
    }
    for (int i = 0; i < n_output; i++) {
      output.push_back (((BitVectorVertexEmbedding*)output_ptr)[i]);
    }
    embeddings = new_embeddings;

    cudaFree (device_embeddings);
    cudaFree (device_new_embeddings);
    cudaFree (device_n_embeddings);
    cudaFree (device_outputs);
    cudaFree (device_n_outputs);
    cudaFree (device_csr);
    delete[] global_mem_ptr;
    #endif
  } 
   */
}
