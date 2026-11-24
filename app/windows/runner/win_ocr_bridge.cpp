#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS
#define _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS
#endif

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Security.Cryptography.h>
#include <winrt/Windows.Storage.Streams.h>

namespace {

using winrt::Windows::Globalization::Language;
using winrt::Windows::Graphics::Imaging::BitmapAlphaMode;
using winrt::Windows::Graphics::Imaging::BitmapPixelFormat;
using winrt::Windows::Graphics::Imaging::SoftwareBitmap;
using winrt::Windows::Media::Ocr::OcrEngine;
using winrt::Windows::Media::Ocr::OcrResult;
using winrt::Windows::Security::Cryptography::CryptographicBuffer;

bool is_ascii_alnum(unsigned char ch) {
  return (ch >= '0' && ch <= '9') ||
         (ch >= 'A' && ch <= 'Z') ||
         (ch >= 'a' && ch <= 'z');
}

void append_json_escaped(std::string& out, const std::string& s) {
  out.push_back('"');
  for (unsigned char c : s) {
    switch (c) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\b':
        out += "\\b";
        break;
      case '\f':
        out += "\\f";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        if (c < 0x20) {
          char buf[8];
          std::snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned>(c));
          out += buf;
        } else {
          out.push_back(static_cast<char>(c));
        }
        break;
    }
  }
  out.push_back('"');
}

char* alloc_c_string(const std::string& str) {
  const size_t len = str.size();
  char* mem = static_cast<char*>(std::malloc(len + 1));
  if (!mem) return nullptr;
  std::memcpy(mem, str.data(), len);
  mem[len] = '\0';
  return mem;
}

double clamp01(double v) {
  if (v < 0.0) return 0.0;
  if (v > 1.0) return 1.0;
  return v;
}

OcrEngine create_engine_for_tag(const std::string& tag) {
  std::vector<const wchar_t*> candidates;
  if (tag == "en") {
    candidates = {L"en-US", L"en-GB", L"en"};
  } else if (tag == "ja") {
    candidates = {L"ja", L"ja-JP"};
  } else {
    candidates = {L"zh-Hans-CN", L"zh-CN", L"zh-Hans", L"zh-Hant-TW", L"zh-HK"};
  }

  for (const wchar_t* lang_tag : candidates) {
    try {
      Language lang{winrt::hstring(lang_tag)};
      if (OcrEngine::IsLanguageSupported(lang)) {
        auto engine = OcrEngine::TryCreateFromLanguage(lang);
        if (engine != nullptr) return engine;
      }
    } catch (...) {
    }
  }
  try {
    return OcrEngine::TryCreateFromUserProfileLanguages();
  } catch (...) {
    return nullptr;
  }
}

}  // namespace

extern "C" {

__declspec(dllexport) uint8_t* bfly_ocr_alloc(int32_t size) {
  const size_t bytes = size > 0 ? static_cast<size_t>(size) : 1;
  return static_cast<uint8_t*>(std::malloc(bytes));
}

__declspec(dllexport) void bfly_ocr_free(void* ptr) {
  std::free(ptr);
}

__declspec(dllexport) char* bfly_ocr_recognize_bgra(
    const uint8_t* pixels,
    int32_t width,
    int32_t height,
    int32_t is_rgba,
    const char* lang_tag) {
  if (!pixels || width <= 0 || height <= 0) {
    return alloc_c_string("{\"ok\":false,\"error\":\"invalid_image\"}");
  }

  try {
    try {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
    } catch (...) {
      // Ignore if thread already initialized with another apartment model.
    }

    const size_t pixel_count =
        static_cast<size_t>(width) * static_cast<size_t>(height);
    const size_t total_bytes = pixel_count * 4;

    winrt::Windows::Storage::Streams::IBuffer buffer = nullptr;
    if (is_rgba != 0) {
      std::vector<uint8_t> bgra(total_bytes);
      for (size_t i = 0; i < total_bytes; i += 4) {
        bgra[i] = pixels[i + 2];
        bgra[i + 1] = pixels[i + 1];
        bgra[i + 2] = pixels[i];
        bgra[i + 3] = pixels[i + 3];
      }
      buffer = CryptographicBuffer::CreateFromByteArray(
          winrt::array_view<uint8_t const>(bgra.data(), bgra.data() + total_bytes));
    } else {
      buffer = CryptographicBuffer::CreateFromByteArray(
          winrt::array_view<uint8_t const>(pixels, pixels + total_bytes));
    }

    SoftwareBitmap bitmap = SoftwareBitmap::CreateCopyFromBuffer(
        buffer,
        BitmapPixelFormat::Bgra8,
        width,
        height,
        BitmapAlphaMode::Premultiplied);

    const std::string tag = lang_tag ? std::string(lang_tag) : "zh_en";
    OcrEngine engine = create_engine_for_tag(tag);
    if (engine == nullptr) {
      return alloc_c_string("{\"ok\":false,\"error\":\"ocr_engine_unavailable\"}");
    }

    OcrResult result = engine.RecognizeAsync(bitmap).get();

    const double w_norm = static_cast<double>(width);
    const double h_norm = static_cast<double>(height);

    std::string out = "{\"ok\":true,\"lines\":[";
    bool first_line = true;

    for (auto const& line : result.Lines()) {
      std::string joined_line;
      std::string words_json = "[";
      bool first_word = true;

      double min_l = 1.0, min_t = 1.0, max_r = 0.0, max_b = 0.0;
      bool has_box = false;

      for (auto const& word : line.Words()) {
        std::string wt = winrt::to_string(word.Text());
        if (wt.empty()) continue;

        auto rect = word.BoundingRect();
        double wl = clamp01(rect.X / w_norm);
        double wt_y = clamp01(rect.Y / h_norm);
        double wr = clamp01((rect.X + rect.Width) / w_norm);
        double wb = clamp01((rect.Y + rect.Height) / h_norm);

        if (!has_box) {
          min_l = wl;
          min_t = wt_y;
          max_r = wr;
          max_b = wb;
          has_box = true;
        } else {
          min_l = std::min(min_l, wl);
          min_t = std::min(min_t, wt_y);
          max_r = std::max(max_r, wr);
          max_b = std::max(max_b, wb);
        }

        if (!joined_line.empty()) {
          unsigned char prev_last = static_cast<unsigned char>(joined_line.back());
          unsigned char next_first = static_cast<unsigned char>(wt.front());
          if (is_ascii_alnum(prev_last) && is_ascii_alnum(next_first)) {
            joined_line.push_back(' ');
          }
        }
        joined_line += wt;

        if (!first_word) words_json.push_back(',');
        first_word = false;
        char coord_buf[160];
        std::snprintf(
            coord_buf,
            sizeof(coord_buf),
            "\"l\":%.6f,\"tp\":%.6f,\"r\":%.6f,\"b\":%.6f",
            wl, wt_y, wr, wb);
        words_json += "{\"t\":";
        append_json_escaped(words_json, wt);
        words_json.push_back(',');
        words_json += coord_buf;
        words_json.push_back('}');
      }
      words_json.push_back(']');

      if (joined_line.empty()) {
        joined_line = winrt::to_string(line.Text());
      }
      if (joined_line.empty() || !has_box) continue;

      if (!first_line) out.push_back(',');
      first_line = false;

      char line_coords[160];
      std::snprintf(
          line_coords,
          sizeof(line_coords),
          "\"l\":%.6f,\"t\":%.6f,\"r\":%.6f,\"b\":%.6f",
          min_l, min_t, max_r, max_b);
      out += "{\"text\":";
      append_json_escaped(out, joined_line);
      out.push_back(',');
      out += line_coords;
      out += ",\"words\":";
      out += words_json;
      out.push_back('}');
    }

    out += "]}";
    return alloc_c_string(out);
  } catch (winrt::hresult_error const& e) {
    std::string msg = winrt::to_string(e.message());
    std::string err = "{\"ok\":false,\"error\":";
    append_json_escaped(err, msg);
    err += "}";
    return alloc_c_string(err);
  } catch (...) {
    return alloc_c_string("{\"ok\":false,\"error\":\"native_ocr_exception\"}");
  }
}

}  // extern "C"
