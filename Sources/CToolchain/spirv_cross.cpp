// SPIRV-Cross's CLI sets dozens of CompilerMSL options from its argument defaults. Rather than copy them and drift,
// this compiles the CLI's own main.cpp into this file and calls its compile_iteration with the arguments
// SPIRVCrossLib passes, so the MSL is what `spirv-cross --msl` prints.

#include "CToolchain.h"

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#define main isftool_unused_spirv_cross_main
#include "../../Vendor/SPIRV-Cross/main.cpp"
#undef main

namespace {

char *copyCString(const std::string &s) {
    char *out = static_cast<char *>(std::malloc(s.size() + 1));
    std::memcpy(out, s.c_str(), s.size() + 1);
    return out;
}

// The CLI's main() prints this for anything compile_iteration throws.
std::string exceptionMessage(const std::exception &e) {
    return std::string("SPIRV-Cross threw an exception: ") + e.what();
}

}

bool isft_spirv_to_msl(const uint32_t *words, size_t count, const char *entryPoint, ISFTStage stage, char **outMSL, char **outError) {
    *outMSL = nullptr;
    *outError = nullptr;
    try {
        CLIArguments args;
        args.msl = true;
        args.entry_point_rename.push_back({"main", entryPoint, stage_to_execution_model(stage == ISFT_STAGE_VERTEX ? "vert" : "frag")});
        *outMSL = copyCString(compile_iteration(args, std::vector<uint32_t>(words, words + count)));
        return true;
    } catch (const std::exception &e) {
        *outError = copyCString(exceptionMessage(e));
        return false;
    }
}

bool isft_spirv_reflect(const uint32_t *words, size_t count, char **outJSON, char **outError) {
    *outJSON = nullptr;
    *outError = nullptr;
    try {
        Parser parser(std::vector<uint32_t>(words, words + count));
        parser.parse();
        CompilerReflection compiler(std::move(parser.get_parsed_ir()));
        compiler.set_format("json");
        *outJSON = copyCString(compiler.compile());
        return true;
    } catch (const std::exception &e) {
        *outError = copyCString(exceptionMessage(e));
        return false;
    }
}

const char *isft_spirv_cross_revision(void) {
    return "66363ac7e8fe4465169ceb2ad5905b1657244cfe";
}
