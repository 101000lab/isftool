#ifndef ISFGLSLBridge_h
#define ISFGLSLBridge_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ISFBDoc ISFBDoc;

// Every function catches VVISF::ISFErr and std::exception so that nothing throws into Swift.
// Strings returned through out parameters or return values are malloc'd and must be released with isfb_free.

ISFBDoc *isfb_open(const char *path, char **outError);
void isfb_close(ISFBDoc *doc);
void isfb_free(void *ptr);

// Runs generateShaderSource(GLVersion_4, inVarsAsUBO=true), the same call as ISFMSLKit.
// The UBO size generateShaderSource reports stays at sizeof(ISFShaderRenderInfo) in UBO mode, so use maxUBOSize from isfb_describe like ISFMSLKit does.
bool isfb_generate(ISFBDoc *doc, char **outFrag, char **outVert, char **outError);

// JSON snapshot of inputs, passes, imports, offsets and raw sources.
// Offsets are relative to the end of ISFShaderRenderInfo, as ISFDoc computes them when it parses the file.
char *isfb_describe(ISFBDoc *doc);

// Sets an input's current value (used by pass size expressions). count is 1 for float/long/bool/event, 2 for point2D, 4 for color.
bool isfb_set_input(ISFBDoc *doc, const char *name, const double *values, int count, char **outError);

bool isfb_eval_pass_sizes(ISFBDoc *doc, int width, int height, char **outError);

#ifdef __cplusplus
}
#endif

#endif
