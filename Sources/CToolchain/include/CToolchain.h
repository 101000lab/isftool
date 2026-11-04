#ifndef CToolchain_h
#define CToolchain_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// glslang and SPIRV-Cross linked in, called the way VIDVOX's GLSLangValidatorLib and SPIRVCrossLib call their CLIs.
// Nothing throws into Swift. Returned buffers are malloc'd and must be released with isft_free.

typedef enum {
    ISFT_STAGE_VERTEX = 0,
    ISFT_STAGE_FRAGMENT = 1,
} ISFTStage;

void isft_free(void *ptr);

// `glslangValidator -G --amb --aml --stdin -S <stage>`. The log is what the CLI prints to stdout, which is what
// GLSLangValidatorLib hands back as its error string; errors read `ERROR: stdin:<line>: ...`.
bool isft_glsl_to_spirv(const char *source, ISFTStage stage, uint32_t **outWords, size_t *outCount, char **outLog);

// `spirv-cross --rename-entry-point main <entryPoint> <stage> --msl -`.
bool isft_spirv_to_msl(const uint32_t *words, size_t count, const char *entryPoint, ISFTStage stage, char **outMSL, char **outError);

// `spirv-cross --reflect`.
bool isft_spirv_reflect(const uint32_t *words, size_t count, char **outJSON, char **outError);

// What `glslangValidator -H` prints after the module.
char *isft_spirv_disassemble(const uint32_t *words, size_t count);

const char *isft_glslang_version(void);
const char *isft_spirv_cross_revision(void);

#ifdef __cplusplus
}
#endif

#endif
