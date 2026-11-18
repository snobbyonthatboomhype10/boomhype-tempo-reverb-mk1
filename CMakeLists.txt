cmake_minimum_required(VERSION 3.22)
project(BoomHypeTempoReverbMK1 VERSION 1.0.0)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

include(FetchContent)
FetchContent_Declare(JUCE
    GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
    GIT_TAG 8.0.6
    GIT_SHALLOW ON)
FetchContent_MakeAvailable(JUCE)

juce_add_plugin(TempoReverb
    COMPANY_NAME "BoomHype Tech"
    COMPANY_WEBSITE "https://boomhype.tech"
    BUNDLE_ID com.boomhypetech.temporeverbmk1
    PLUGIN_MANUFACTURER_CODE Bhtc
    PLUGIN_CODE Trv1
    FORMATS VST3
    PRODUCT_NAME "Tempo Reverb MK I"
    VST3_CATEGORIES Fx Reverb
    IS_SYNTH FALSE
    NEEDS_MIDI_INPUT FALSE
    NEEDS_MIDI_OUTPUT FALSE
    IS_MIDI_EFFECT FALSE
    COPY_PLUGIN_AFTER_BUILD FALSE)

target_sources(TempoReverb PRIVATE
    Source/PluginProcessor.cpp
    Source/PluginEditor.cpp)

# ---- fonts: Josefin Sans + Bevan (SIL OFL) are stored as .woff2 and converted to .ttf at configure time
set(BH_FONTS_OK OFF)
find_package(Python3 COMPONENTS Interpreter)
if(Python3_FOUND)
    execute_process(COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tools/woff2ttf.py
                            ${CMAKE_CURRENT_SOURCE_DIR}/assets/fonts ${CMAKE_BINARY_DIR}/fonts
                    RESULT_VARIABLE BH_FONT_RC)
    if(BH_FONT_RC EQUAL 0)
        set(BH_FONTS_OK ON)
    endif()
endif()
if(BH_FONTS_OK)
    juce_add_binary_data(BHAssets SOURCES
        ${CMAKE_BINARY_DIR}/fonts/Josefin500.ttf
        ${CMAKE_BINARY_DIR}/fonts/Josefin600.ttf
        ${CMAKE_BINARY_DIR}/fonts/Josefin700.ttf
        ${CMAKE_BINARY_DIR}/fonts/Bevan400.ttf)
    target_link_libraries(TempoReverb PRIVATE BHAssets)
    target_compile_definitions(TempoReverb PUBLIC BH_HAS_FONTS=1)
else()
    message(WARNING "Font conversion failed - building with system fonts (plugin still works)")
    target_compile_definitions(TempoReverb PUBLIC BH_HAS_FONTS=0)
endif()

target_compile_definitions(TempoReverb PUBLIC
    JUCE_WEB_BROWSER=0
    JUCE_USE_CURL=0
    JUCE_VST3_CAN_REPLACE_VST2=0
    JUCE_DISPLAY_SPLASH_SCREEN=1)

target_link_libraries(TempoReverb
    PRIVATE
        juce::juce_audio_utils
        juce::juce_dsp
    PUBLIC
        juce::juce_recommended_config_flags
        juce::juce_recommended_warning_flags)
