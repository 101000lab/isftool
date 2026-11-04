#include "ISFGLSLBridge.h"

#include <cstdlib>
#include <cstring>
#include <exception>
#include <string>

#include "VVISF.hpp"
#include "json.hpp"

using json = nlohmann::json;

struct ISFBDoc {
    VVISF::ISFDocRef doc;
};

static char *copyString(const std::string &s) {
    char *out = static_cast<char *>(std::malloc(s.size() + 1));
    if (out != nullptr) {
        std::memcpy(out, s.c_str(), s.size() + 1);
    }
    return out;
}

static void setError(char **outError, const std::string &message) {
    if (outError != nullptr) {
        *outError = copyString(message);
    }
}

static std::string describeISFErr(const VVISF::ISFErr &err) {
    std::string message = err.getTypeString() + ": " + err.general;
    if (!err.specific.empty()) {
        message += " (" + err.specific + ")";
    }
    for (const auto &[key, value] : err.details) {
        if (key == "fragSrc" || key == "vertSrc") {
            continue;
        }
        message += "\n" + key + ": " + value;
    }
    return message;
}

template <typename F>
static bool guarded(char **outError, F body) {
    try {
        body();
        return true;
    } catch (const VVISF::ISFErr &err) {
        setError(outError, describeISFErr(err));
    } catch (const std::exception &err) {
        setError(outError, err.what());
    } catch (...) {
        setError(outError, "unknown C++ exception");
    }
    return false;
}

static json valueToJSON(const VVISF::ISFVal &val) {
    using namespace VVISF;
    switch (val.type()) {
    case ISFValType_Event:
    case ISFValType_Bool:
        return val.getBoolVal();
    case ISFValType_Long:
        return val.getLongVal();
    case ISFValType_Float:
        return val.getDoubleVal();
    case ISFValType_Point2D: {
        auto &v = const_cast<ISFVal &>(val);
        return json::array({v.getPointValByIndex(0), v.getPointValByIndex(1)});
    }
    case ISFValType_Color: {
        auto &v = const_cast<ISFVal &>(val);
        return json::array({v.getColorValByChannel(0), v.getColorValByChannel(1), v.getColorValByChannel(2), v.getColorValByChannel(3)});
    }
    default:
        return nullptr;
    }
}

static json offsetToJSON(uint32_t offset) {
    if (offset == std::numeric_limits<uint32_t>::max()) {
        return nullptr;
    }
    return offset;
}

extern "C" {

ISFBDoc *isfb_open(const char *path, char **outError) {
    ISFBDoc *result = nullptr;
    guarded(outError, [&] {
        auto doc = VVISF::CreateISFDocRef(std::string(path), true);
        result = new ISFBDoc{doc};
    });
    return result;
}

void isfb_close(ISFBDoc *doc) { delete doc; }

void isfb_free(void *ptr) { std::free(ptr); }

bool isfb_generate(ISFBDoc *doc, char **outFrag, char **outVert, char **outError) {
    return guarded(outError, [&] {
        std::string frag;
        std::string vert;
        if (!doc->doc->generateShaderSource(&frag, &vert, VVISF::GLVersion_4, true)) {
            throw std::runtime_error("generateShaderSource returned false");
        }
        *outFrag = copyString(frag);
        *outVert = copyString(vert);
    });
}

char *isfb_describe(ISFBDoc *doc) {
    json out;
    guarded(nullptr, [&] {
        auto &d = *doc->doc;
        json inputs = json::array();
        for (const auto &attr : d.inputs()) {
            json labels = json::array();
            for (const auto &l : attr->labelArray()) labels.push_back(l);
            json values = json::array();
            for (const auto &v : attr->valArray()) values.push_back(v);
            inputs.push_back({
                {"name", attr->name()},
                {"type", VVISF::StringFromISFValType(attr->type())},
                {"label", attr->label()},
                {"default", valueToJSON(attr->defaultVal())},
                {"min", valueToJSON(attr->minVal())},
                {"max", valueToJSON(attr->maxVal())},
                {"identity", valueToJSON(attr->identityVal())},
                {"current", valueToJSON(attr->currentVal())},
                {"labels", labels},
                {"values", values},
                {"offset", offsetToJSON(attr->offsetInBuffer())},
            });
        }
        json passes = json::array();
        for (const auto &pass : d.renderPasses()) {
            auto info = pass->targetImageInfo();
            passes.push_back({
                {"target", pass->name()},
                {"persistent", pass->persistentFlag()},
                {"float", pass->floatFlag()},
                {"widthExpression", pass->targetWidthString()},
                {"heightExpression", pass->targetHeightString()},
                {"width", info.width},
                {"height", info.height},
                {"offset", offsetToJSON(pass->offsetInBuffer())},
            });
        }
        json imports = json::array();
        for (const auto &attr : d.imageImports()) {
            imports.push_back({
                {"name", attr->name()},
                {"path", attr->description()},
                {"offset", offsetToJSON(attr->offsetInBuffer())},
            });
        }
        std::string jsonSource;
        if (d.jsonSourceString() != nullptr) jsonSource = *d.jsonSourceString();
        std::string fragSource;
        if (d.fragShaderSource() != nullptr) fragSource = *d.fragShaderSource();
        std::string vertSource;
        if (d.vertShaderSource() != nullptr) vertSource = *d.vertShaderSource();
        out = {
            {"path", d.path()},
            {"name", d.name()},
            {"description", d.description()},
            {"hasCustomVertShader", d.hasCustomVertShader()},
            {"maxUBOSize", d.getMaxUBOSize()},
            {"inputs", inputs},
            {"passes", passes},
            {"imports", imports},
            {"jsonSource", jsonSource},
            {"fragSource", fragSource},
            {"vertSource", vertSource},
        };
    });
    return copyString(out.dump(-1, ' ', false, json::error_handler_t::replace));
}

bool isfb_set_input(ISFBDoc *doc, const char *name, const double *values, int count, char **outError) {
    return guarded(outError, [&] {
        auto attr = doc->doc->input(std::string(name));
        if (attr == nullptr) {
            throw std::runtime_error(std::string("no such input: ") + name);
        }
        using namespace VVISF;
        auto need = [&](int n) {
            if (count < n) throw std::runtime_error(std::string("not enough values for input: ") + name);
        };
        switch (attr->type()) {
        case ISFValType_Event:
        case ISFValType_Bool:
            need(1);
            attr->setCurrentVal(ISFVal(attr->type(), values[0] != 0.0));
            break;
        case ISFValType_Long:
            need(1);
            attr->setCurrentVal(ISFVal(ISFValType_Long, static_cast<int32_t>(values[0])));
            break;
        case ISFValType_Float:
            need(1);
            attr->setCurrentVal(ISFVal(ISFValType_Float, values[0]));
            break;
        case ISFValType_Point2D:
            need(2);
            attr->setCurrentVal(ISFVal(ISFValType_Point2D, values[0], values[1]));
            break;
        case ISFValType_Color:
            need(4);
            attr->setCurrentVal(ISFVal(ISFValType_Color, values[0], values[1], values[2], values[3]));
            break;
        default:
            throw std::runtime_error(std::string("input does not take a value: ") + name);
        }
    });
}

bool isfb_eval_pass_sizes(ISFBDoc *doc, int width, int height, char **outError) {
    return guarded(outError, [&] { doc->doc->evalBufferDimensionsWithRenderSize(width, height); });
}

}
