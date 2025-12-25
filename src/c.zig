const c_import = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
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
pub const SDL_RenderDrawRect = c_import.SDL_RenderDrawRect;
pub const SDL_RenderDrawLine = c_import.SDL_RenderDrawLine;
pub const SDL_RenderDrawPoint = c_import.SDL_RenderDrawPoint;
pub const SDL_RenderCopy = c_import.SDL_RenderCopy;
pub const SDL_SetRenderDrawBlendMode = c_import.SDL_SetRenderDrawBlendMode;
pub const SDL_QueryTexture = c_import.SDL_QueryTexture;
pub const SDL_CreateTextureFromSurface = c_import.SDL_CreateTextureFromSurface;
pub const SDL_DestroyTexture = c_import.SDL_DestroyTexture;
pub const SDL_FreeSurface = c_import.SDL_FreeSurface;
pub const SDL_GetError = c_import.SDL_GetError;
pub const SDL_PollEvent = c_import.SDL_PollEvent;
pub const SDL_Delay = c_import.SDL_Delay;

pub const SDL_INIT_VIDEO = c_import.SDL_INIT_VIDEO;
pub const SDL_WINDOW_SHOWN = c_import.SDL_WINDOW_SHOWN;
pub const SDL_WINDOWPOS_CENTERED = c_import.SDL_WINDOWPOS_CENTERED;
pub const SDL_RENDERER_ACCELERATED = c_import.SDL_RENDERER_ACCELERATED;
pub const SDL_BLENDMODE_BLEND = c_import.SDL_BLENDMODE_BLEND;
pub const SDL_QUIT = c_import.SDL_QUIT;
pub const SDL_KEYDOWN = c_import.SDL_KEYDOWN;
pub const SDL_MOUSEBUTTONDOWN = c_import.SDL_MOUSEBUTTONDOWN;

pub const SDL_HINT_RENDER_SCALE_QUALITY = c_import.SDL_HINT_RENDER_SCALE_QUALITY;
pub const SDL_SetHint = c_import.SDL_SetHint;
pub const SDL_SetTextureScaleMode = c_import.SDL_SetTextureScaleMode;
pub const SDL_ScaleModeLinear = c_import.SDL_ScaleModeLinear;

pub const SDLK_ESCAPE = c_import.SDLK_ESCAPE;
pub const SDLK_RETURN = c_import.SDLK_RETURN;
pub const SDLK_BACKSPACE = c_import.SDLK_BACKSPACE;
pub const SDLK_UP = c_import.SDLK_UP;
pub const SDLK_DOWN = c_import.SDLK_DOWN;
pub const SDLK_LEFT = c_import.SDLK_LEFT;
pub const SDLK_RIGHT = c_import.SDLK_RIGHT;
pub const KMOD_CTRL = c_import.KMOD_CTRL;

pub const TTF_Init = c_import.TTF_Init;
pub const TTF_Quit = c_import.TTF_Quit;
pub const TTF_OpenFont = c_import.TTF_OpenFont;
pub const TTF_CloseFont = c_import.TTF_CloseFont;
pub const TTF_RenderText_Blended = c_import.TTF_RenderText_Blended;
pub const TTF_RenderGlyph_Blended = c_import.TTF_RenderGlyph_Blended;
pub const TTF_SizeText = c_import.TTF_SizeText;
pub const TTF_GetError = c_import.TTF_GetError;

pub const SDL_Event = c_import.SDL_Event;
pub const SDL_Rect = c_import.SDL_Rect;
pub const SDL_Color = c_import.SDL_Color;
pub const SDL_Renderer = c_import.SDL_Renderer;
pub const SDL_Window = c_import.SDL_Window;
pub const SDL_Texture = c_import.SDL_Texture;
pub const SDL_Surface = c_import.SDL_Surface;
pub const SDL_Keysym = c_import.SDL_Keysym;
pub const TTF_Font = c_import.TTF_Font;
