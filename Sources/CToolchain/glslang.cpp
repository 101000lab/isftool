// Mirrors the branches of glslang's StandAlone.cpp (CompileAndLinkShaderUnits) that `-G --amb --aml --stdin -S <stage>`
// takes, at the commit VDMX's GLSLangValidatorLib was built from. GLSLangValidatorLib itself is not used: it runs the
// CLI's main() under a global lock with stdout redirected, which would swallow isftool's own output.

#include "CToolchain.h"

#include <cstdlib>
#include <cstring>
#include <list>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

#include "glslang/Public/ShaderLang.h"
#include "glslang/Public/ResourceLimits.h"
#include "glslang/build_info.h"
#include "SPIRV/GlslangToSpv.h"
#include "SPIRV/disassemble.h"
#include "StandAlone/DirStackFileIncluder.h"
#include "glslang/glsl_intrinsic_header.h"

namespace {

char *copyString(const std::string &s) {
    char *out = static_cast<char *>(std::malloc(s.size() + 1));
    std::memcpy(out, s.c_str(), s.size() + 1);
    return out;
}

// The CLI prints logs with puts, which appends a newline.
void putsIfNonEmpty(std::string &log, const char *s) {
    if (s && s[0]) {
        log += s;
        log += "\n";
    }
}

void initializeOnce() {
    static std::once_flag flag;
    std::call_once(flag, [] { glslang::InitializeProcess(); });
}

}

void isft_free(void *ptr) { std::free(ptr); }

bool isft_glsl_to_spirv(const char *source, ISFTStage stage, uint32_t **outWords, size_t *outCount, char **outLog) {
    *outWords = nullptr;
    *outCount = 0;
    *outLog = nullptr;
    initializeOnce();

    const EShLanguage language = stage == ISFT_STAGE_VERTEX ? EShLangVertex : EShLangFragment;
    // SetMessageOptions with EOptionSpv, and with HLSL legalization because VDMX's build has ENABLE_OPT off.
    const EShMessages messages = static_cast<EShMessages>(EShMsgDefault | EShMsgSpvRules | EShMsgHlslLegalization);

    std::string log;
    bool failed = false;
    std::vector<unsigned int> spirv;
    try {
        DirStackFileIncluder includer;
        glslang::TProgram *program = new glslang::TProgram;
        glslang::TShader *shader = new glslang::TShader(language);

        const char *texts[] = {source};
        const char *names[] = {"stdin"};
        shader->setStringsWithLengthsAndNames(texts, nullptr, names, 1);
        shader->setOverrideVersion(0);
        const std::string preamble = getIntrinsic(texts, 1);
        shader->setPreamble(preamble.c_str());
        shader->addProcesses({});
        for (int r = 0; r < glslang::EResCount; ++r)
            shader->setShiftBinding(glslang::TResourceType(r), 0);
        shader->setNoStorageFormat(false);
        shader->setResourceSetBinding({});
        shader->setAutoMapBindings(true);
        shader->setAutoMapLocations(true);
        shader->setUniformLocationBase(0);
        shader->setNanMinMaxClamp(false);
        shader->setFlattenUniformArrays(false);
        shader->setEnvInput(glslang::EShSourceGlsl, language, glslang::EShClientOpenGL, 100);
        shader->setEnvClient(glslang::EShClientOpenGL, glslang::EShTargetOpenGL_450);
        shader->setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_0);

        if (!shader->parse(GetDefaultResources(), 100, false, messages, includer))
            failed = true;
        program->addShader(shader);
        // GLSLangValidatorLib comments out the line naming the file, so the log starts with the messages.
        putsIfNonEmpty(log, shader->getInfoLog());
        putsIfNonEmpty(log, shader->getInfoDebugLog());

        if (!program->link(messages))
            failed = true;
        if (!program->mapIO())
            failed = true;
        putsIfNonEmpty(log, program->getInfoLog());
        putsIfNonEmpty(log, program->getInfoDebugLog());

        if (failed) {
            log += "SPIR-V is not generated for failed compile or link\n";
        } else if (glslang::TIntermediate *intermediate = program->getIntermediate(language)) {
            spv::SpvBuildLogger logger;
            glslang::SpvOptions options;
            options.disableOptimizer = false;
            options.optimizeSize = false;
            options.disassemble = false;
            options.validate = false;
            options.compileOnly = false;
            glslang::GlslangToSpv(*intermediate, spirv, &logger, &options);
            log += logger.getAllMessages();
        }

        // The program goes first: it may hold things merged from the shader, whose pool the shader frees.
        delete program;
        delete shader;
    } catch (const std::exception &e) {
        log += e.what();
        failed = true;
    }

    *outLog = copyString(log);
    if (failed || spirv.empty())
        return false;
    *outWords = static_cast<uint32_t *>(std::malloc(spirv.size() * sizeof(uint32_t)));
    std::memcpy(*outWords, spirv.data(), spirv.size() * sizeof(uint32_t));
    *outCount = spirv.size();
    return true;
}

char *isft_spirv_disassemble(const uint32_t *words, size_t count) {
    std::vector<unsigned int> spirv(words, words + count);
    std::ostringstream out;
    spv::Disassemble(out, spirv);
    return copyString(out.str());
}

const char *isft_glslang_version(void) {
    static const std::string version = std::to_string(GLSLANG_VERSION_MAJOR) + "." + std::to_string(GLSLANG_VERSION_MINOR) + "." +
                                       std::to_string(GLSLANG_VERSION_PATCH) + GLSLANG_VERSION_FLAVOR;
    return version.c_str();
}
