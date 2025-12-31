// Minimal re-export layer that isolates C includes so the rest of the codebase
// can `@import("c.zig")` without pulling headers repeatedly.
const c_import = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
});

pub const SDL_Init = c_import.SDL_Init;
pub const SDL_Quit = c_import.SDL_Quit;
pub const SDL_CreateWindow = c_import.SDL_CreateWindow;
pub const SDL_DestroyWindow = c_import.SDL_DestroyWindow;
pub const SDL_CreateRenderer = c_import.SDL_CreateRenderer;
pub const SDL_DestroyRenderer = c_import.SDL_DestroyRenderer;
pub const SDL_SetRenderDrawColor = c_import.SDL_SetRenderDrawColor;
pub const SDL_RenderClear = c_import.SDL_RenderClear;
pub const SDL_RenderPresent = c_import.SDL_RenderPresent;
pub const SDL_RenderFillRect = c_import.SDL_RenderFillRect;
pub const SDL_RenderRect = c_import.SDL_RenderRect;
pub const SDL_RenderLine = c_import.SDL_RenderLine;
pub const SDL_RenderPoint = c_import.SDL_RenderPoint;
pub const SDL_CreateTexture = c_import.SDL_CreateTexture;
pub const SDL_SetRenderTarget = c_import.SDL_SetRenderTarget;
pub const SDL_SetTextureBlendMode = c_import.SDL_SetTextureBlendMode;
pub const SDL_SetRenderVSync = c_import.SDL_SetRenderVSync;
pub const SDL_RenderTexture = c_import.SDL_RenderTexture;
pub const SDL_SetRenderDrawBlendMode = c_import.SDL_SetRenderDrawBlendMode;
pub const SDL_GetTextureSize = c_import.SDL_GetTextureSize;
pub const SDL_CreateTextureFromSurface = c_import.SDL_CreateTextureFromSurface;
pub const SDL_DestroyTexture = c_import.SDL_DestroyTexture;
pub const SDL_DestroySurface = c_import.SDL_DestroySurface;
pub const SDL_GetError = c_import.SDL_GetError;
pub const SDL_PollEvent = c_import.SDL_PollEvent;
pub const SDL_Delay = c_import.SDL_Delay;
pub const SDL_StartTextInput = c_import.SDL_StartTextInput;
pub const SDL_StopTextInput = c_import.SDL_StopTextInput;

pub const SDL_INIT_VIDEO = c_import.SDL_INIT_VIDEO;
pub const SDL_BLENDMODE_BLEND = c_import.SDL_BLENDMODE_BLEND;
pub const SDL_BLENDMODE_NONE = c_import.SDL_BLENDMODE_NONE;
pub const SDL_WINDOW_RESIZABLE = c_import.SDL_WINDOW_RESIZABLE;
pub const SDL_EVENT_QUIT = c_import.SDL_EVENT_QUIT;
pub const SDL_EVENT_KEY_DOWN = c_import.SDL_EVENT_KEY_DOWN;
pub const SDL_EVENT_TEXT_INPUT = c_import.SDL_EVENT_TEXT_INPUT;
pub const SDL_EVENT_MOUSE_BUTTON_DOWN = c_import.SDL_EVENT_MOUSE_BUTTON_DOWN;
pub const SDL_EVENT_MOUSE_WHEEL = c_import.SDL_EVENT_MOUSE_WHEEL;
pub const SDL_EVENT_WINDOW_RESIZED = c_import.SDL_EVENT_WINDOW_RESIZED;

pub const SDL_SetTextureScaleMode = c_import.SDL_SetTextureScaleMode;
pub const SDL_SCALEMODE_LINEAR = c_import.SDL_SCALEMODE_LINEAR;

pub const SDLK_ESCAPE = c_import.SDLK_ESCAPE;
pub const SDLK_RETURN = c_import.SDLK_RETURN;
pub const SDLK_BACKSPACE = c_import.SDLK_BACKSPACE;
pub const SDLK_UP = c_import.SDLK_UP;
pub const SDLK_DOWN = c_import.SDLK_DOWN;
pub const SDLK_LEFT = c_import.SDLK_LEFT;
pub const SDLK_RIGHT = c_import.SDLK_RIGHT;
pub const SDLK_A = c_import.SDLK_A;
pub const SDLK_Z = c_import.SDLK_Z;
pub const SDLK_LEFTBRACKET = c_import.SDLK_LEFTBRACKET;
pub const SDLK_RIGHTBRACKET = c_import.SDLK_RIGHTBRACKET;
pub const SDL_KMOD_CTRL = c_import.SDL_KMOD_CTRL;
pub const SDL_KMOD_SHIFT = c_import.SDL_KMOD_SHIFT;
pub const SDL_KMOD_GUI = c_import.SDL_KMOD_GUI;
pub const SDL_PIXELFORMAT_RGBA8888 = c_import.SDL_PIXELFORMAT_RGBA8888;
pub const SDL_TEXTUREACCESS_TARGET = c_import.SDL_TEXTUREACCESS_TARGET;

pub const TTF_Init = c_import.TTF_Init;
pub const TTF_Quit = c_import.TTF_Quit;
pub const TTF_OpenFont = c_import.TTF_OpenFont;
pub const TTF_CloseFont = c_import.TTF_CloseFont;
pub const TTF_RenderText_Blended = c_import.TTF_RenderText_Blended;
pub const TTF_RenderGlyph_Blended = c_import.TTF_RenderGlyph_Blended;
pub const TTF_GetStringSize = c_import.TTF_GetStringSize;

pub const SDL_Event = c_import.SDL_Event;
pub const SDL_FRect = c_import.SDL_FRect;
pub const SDL_Rect = c_import.SDL_Rect;
pub const SDL_FColor = c_import.SDL_FColor;
pub const SDL_Color = c_import.SDL_Color;
pub const SDL_Renderer = c_import.SDL_Renderer;
pub const SDL_Window = c_import.SDL_Window;
pub const SDL_Texture = c_import.SDL_Texture;
pub const SDL_Surface = c_import.SDL_Surface;
pub const SDL_Keycode = c_import.SDL_Keycode;
pub const SDL_Keymod = c_import.SDL_Keymod;
pub const TTF_Font = c_import.TTF_Font;
