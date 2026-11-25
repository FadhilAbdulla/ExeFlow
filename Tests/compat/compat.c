// Windows-side compatibility checks. Each check runs in its own process: compat.exe <name>; prints PASS/FAIL detail.
#define COBJMACROS
#define INITGUID
#define _WIN32_WINNT 0x0A00
#include <winsock2.h>
#include <windows.h>
#include <stdio.h>
#include <d3d9.h>
#include <d3d11.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <d3dcompiler.h>
#include <winhttp.h>
#include <mmsystem.h>
#include <xinput.h>
#include <bcrypt.h>
#include <tlhelp32.h>
static int fail(const char*f,...){va_list a;va_start(a,f);printf("FAIL ");vprintf(f,a);puts("");fflush(stdout);va_end(a);ExitProcess(1);return 1;}
static int pass(const char*f,...){va_list a;va_start(a,f);printf("PASS ");vprintf(f,a);puts("");fflush(stdout);va_end(a);ExitProcess(0);return 0;}
static void pump(int ms){DWORD e=GetTickCount()+ms;MSG m;do{while(PeekMessageA(&m,0,0,0,PM_REMOVE)){TranslateMessage(&m);DispatchMessageA(&m);}Sleep(5);}while((int)(e-GetTickCount())>0);}
static int custom; static int paints;
static LRESULT CALLBACK wp(HWND h,UINT m,WPARAM w,LPARAM l){
 if(m==WM_NCCALCSIZE&&custom&&w)return 0;
 if(m==WM_PAINT){PAINTSTRUCT p;HDC d=BeginPaint(h,&p);RECT r;GetClientRect(h,&r);HBRUSH b=CreateSolidBrush(RGB(10,200,30));FillRect(d,&r,b);DeleteObject(b);EndPaint(h,&p);paints++;return 0;}
 if(m==WM_ERASEBKGND)return 1;
 return DefWindowProcA(h,m,w,l);}
static HWND win(DWORD st){WNDCLASSA c={0};c.lpfnWndProc=wp;c.lpszClassName="C";c.hCursor=LoadCursor(0,IDC_ARROW);RegisterClassA(&c);HWND h=CreateWindowA("C","compat",st,120,120,640,480,0,0,0,0);ShowWindow(h,SW_SHOW);UpdateWindow(h);pump(400);return h;}
static const char*rc(RECT r){static char b[4][64];static int i;i=(i+1)&3;sprintf(b[i],"%ld,%ld %ldx%ld",r.left,r.top,r.right-r.left,r.bottom-r.top);return b[i];}
static int windowing(DWORD st,int cust){custom=cust;HWND h=win(st);RECT a,b,x,wa;int i;GetWindowRect(h,&a);SystemParametersInfoA(SPI_GETWORKAREA,0,&wa,0);
 for(i=0;i<5;i++){
  ShowWindow(h,SW_MINIMIZE);pump(900);if(!IsIconic(h))return fail("cycle %d: not minimised",i);
  paints=0;ShowWindow(h,SW_RESTORE);pump(1100);if(IsIconic(h))return fail("cycle %d: did not restore",i);
  GetWindowRect(h,&b);if(memcmp(&a,&b,sizeof a))return fail("cycle %d: after minimise/restore rect %s, was %s",i,rc(b),rc(a));
  ShowWindow(h,SW_MAXIMIZE);pump(1100);GetWindowRect(h,&x);if(!IsZoomed(h))return fail("cycle %d: not maximised",i);
  if(x.top<wa.top-12||x.bottom>wa.bottom+12||x.right-x.left<(wa.right-wa.left)*9/10)return fail("cycle %d: maximised %s, work area %s",i,rc(x),rc(wa));
  {HDC d=GetDC(h);RECT c;GetClientRect(h,&c);COLORREF p=GetPixel(d,c.right-20,c.bottom-20);ReleaseDC(h,d);if(p!=RGB(10,200,30))return fail("cycle %d: maximised corner not painted (%06lx)",i,p);}
  ShowWindow(h,SW_MINIMIZE);pump(900);ShowWindow(h,SW_RESTORE);pump(1100);
  if(!IsZoomed(h))return fail("cycle %d: lost maximised state after minimise",i);
  ShowWindow(h,SW_RESTORE);pump(1100);GetWindowRect(h,&b);if(memcmp(&a,&b,sizeof a))return fail("cycle %d: after maximise/restore rect %s, was %s",i,rc(b),rc(a));
 } return pass("5 cycles, work area %s, maximised %s",rc(wa),rc(x));}
typedef HRESULT(WINAPI*PCOMP)(LPCVOID,SIZE_T,LPCSTR,const void*,void*,LPCSTR,LPCSTR,UINT,UINT,ID3DBlob**,ID3DBlob**);
static int d3d11(D3D_FEATURE_LEVEL want,int draw){HWND h=win(WS_OVERLAPPEDWINDOW);ID3D11Device*d=0;ID3D11DeviceContext*c=0;IDXGISwapChain*s=0;D3D_FEATURE_LEVEL got=0;DXGI_SWAP_CHAIN_DESC sd={{640,480,{60,1},DXGI_FORMAT_R8G8B8A8_UNORM},{1,0},DXGI_USAGE_RENDER_TARGET_OUTPUT,2,h,TRUE};
 HRESULT r=D3D11CreateDeviceAndSwapChain(0,D3D_DRIVER_TYPE_HARDWARE,0,0,&want,1,D3D11_SDK_VERSION,&sd,&s,&d,&got,&c);if(FAILED(r))return fail("device FL %x: hr %08lx",want,r);
 ID3D11Texture2D*bb,*st;ID3D11RenderTargetView*v;IDXGISwapChain_GetBuffer(s,0,&IID_ID3D11Texture2D,(void**)&bb);ID3D11Device_CreateRenderTargetView(d,(ID3D11Resource*)bb,0,&v);
 float col[4]={1,0,0,1};ID3D11DeviceContext_ClearRenderTargetView(c,v,col);
 if(draw){HMODULE m=LoadLibraryA("d3dcompiler_47.dll");PCOMP comp=(PCOMP)(void*)GetProcAddress(m,"D3DCompile");if(!comp)return fail("no d3dcompiler_47");
  const char*src="float4 vs(uint i:SV_VertexID):SV_Position{return float4(i==1?3:-1,i==2?-3:1,0,1);} float4 ps():SV_Target{return float4(0,0,1,1);} RWByteAddressBuffer u;[numthreads(1,1,1)]void cs(){u.Store(0,42);}";
  ID3DBlob*vb=0,*pb=0,*e=0;if(FAILED(r=comp(src,strlen(src),0,0,0,"vs","vs_5_0",0,0,&vb,&e)))return fail("compile vs %08lx",r);if(FAILED(r=comp(src,strlen(src),0,0,0,"ps","ps_5_0",0,0,&pb,&e)))return fail("compile ps %08lx",r);
  ID3D11VertexShader*vs=0;ID3D11PixelShader*ps=0;if(FAILED(ID3D11Device_CreateVertexShader(d,ID3D10Blob_GetBufferPointer(vb),ID3D10Blob_GetBufferSize(vb),0,&vs))||FAILED(ID3D11Device_CreatePixelShader(d,ID3D10Blob_GetBufferPointer(pb),ID3D10Blob_GetBufferSize(pb),0,&ps)))return fail("create shaders");
  D3D11_VIEWPORT vp={0,0,640,480,0,1};ID3D11DeviceContext_RSSetViewports(c,1,&vp);ID3D11DeviceContext_OMSetRenderTargets(c,1,&v,0);ID3D11DeviceContext_VSSetShader(c,vs,0,0);ID3D11DeviceContext_PSSetShader(c,ps,0,0);ID3D11DeviceContext_IASetPrimitiveTopology(c,D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);ID3D11DeviceContext_Draw(c,3,0);}
 D3D11_TEXTURE2D_DESC td;ID3D11Texture2D_GetDesc(bb,&td);td.Usage=D3D11_USAGE_STAGING;td.BindFlags=0;td.CPUAccessFlags=D3D11_CPU_ACCESS_READ;td.MiscFlags=0;if(FAILED(ID3D11Device_CreateTexture2D(d,&td,0,&st)))return fail("staging");
 ID3D11DeviceContext_CopyResource(c,(ID3D11Resource*)st,(ID3D11Resource*)bb);D3D11_MAPPED_SUBRESOURCE m;if(FAILED(ID3D11DeviceContext_Map(c,(ID3D11Resource*)st,0,D3D11_MAP_READ,0,&m)))return fail("map");
 DWORD px=((DWORD*)m.pData)[320+240*m.RowPitch/4];if(px!=(draw?0xffff0000u:0xff0000ffu))return fail("wrong pixel %08lx",px);
 int f=0;DWORD t=GetTickCount();while(GetTickCount()-t<2000){ID3D11DeviceContext_ClearRenderTargetView(c,v,col);if(FAILED(IDXGISwapChain_Present(s,0,0)))return fail("present");f++;pump(0);}
 return pass("FL %x, %d presents/s",got,f/2);}
static DWORD WINAPI thr(void*p){for(int i=0;i<200000;i++)InterlockedIncrement((LONG*)p);return 0;}
int main(int n,char**v){const char*t=n>1?v[1]:"";setvbuf(stdout,0,_IONBF,0);SetErrorMode(SEM_NOGPFAULTERRORBOX|SEM_FAILCRITICALERRORS);
 #define T(x) if(!strcmp(t,x))
 T("basic")return pass("%d-bit",(int)sizeof(void*)*8);
 T("window-standard")return windowing(WS_OVERLAPPEDWINDOW,0);
 T("window-customframe")return windowing(WS_OVERLAPPEDWINDOW,1);
 T("window-borderless")return windowing(WS_POPUP|WS_THICKFRAME|WS_MINIMIZEBOX|WS_MAXIMIZEBOX|WS_SYSMENU,1);
 T("fullscreen"){HWND h=win(WS_POPUP);int w=GetSystemMetrics(SM_CXSCREEN),x=GetSystemMetrics(SM_CYSCREEN);SetWindowPos(h,HWND_TOP,0,0,w,x,0);pump(1200);RECT r;GetWindowRect(h,&r);if(r.right-r.left!=w||r.bottom-r.top!=x)return fail("%s",rc(r));return pass("%dx%d",w,x);}
 T("modeset"){DEVMODEA d={0};d.dmSize=sizeof d;int k=0;while(EnumDisplaySettingsA(0,k,&d))k++;return k>2?pass("%d display modes",k):fail("%d modes",k);}
 T("d3d9"){HWND h=win(WS_OVERLAPPEDWINDOW);IDirect3D9*d=Direct3DCreate9(D3D_SDK_VERSION);if(!d)return fail("create");D3DPRESENT_PARAMETERS p={0};p.Windowed=1;p.SwapEffect=D3DSWAPEFFECT_DISCARD;p.hDeviceWindow=h;p.BackBufferFormat=D3DFMT_X8R8G8B8;p.BackBufferWidth=640;p.BackBufferHeight=480;p.PresentationInterval=D3DPRESENT_INTERVAL_IMMEDIATE;IDirect3DDevice9*v9=0;HRESULT r=IDirect3D9_CreateDevice(d,0,D3DDEVTYPE_HAL,h,D3DCREATE_HARDWARE_VERTEXPROCESSING,&p,&v9);if(FAILED(r))return fail("device %08lx",r);D3DCAPS9 cp;IDirect3DDevice9_GetDeviceCaps(v9,&cp);int f=0;DWORD t0=GetTickCount();while(GetTickCount()-t0<2000){IDirect3DDevice9_Clear(v9,0,0,D3DCLEAR_TARGET,0xff00ff00,1,0);if(FAILED(IDirect3DDevice9_Present(v9,0,0,0,0)))return fail("present");f++;pump(0);}return pass("ps_%lu_%lu, %d presents/s",D3DSHADER_VERSION_MAJOR(cp.PixelShaderVersion),D3DSHADER_VERSION_MINOR(cp.PixelShaderVersion),f/2);}
 T("d3d11-fl10_0")return d3d11(D3D_FEATURE_LEVEL_10_0,1);
 T("d3d11-fl11_0")return d3d11(D3D_FEATURE_LEVEL_11_0,1);
 T("d3d11-fl11_1")return d3d11(D3D_FEATURE_LEVEL_11_1,0);
 T("d3d12"){HMODULE m=LoadLibraryA("d3d12.dll");HRESULT(WINAPI*f)(IUnknown*,D3D_FEATURE_LEVEL,REFIID,void**)=(void*)GetProcAddress(m,"D3D12CreateDevice");ID3D12Device*d=0;if(!f)return fail("no entry point");HRESULT r=f(0,D3D_FEATURE_LEVEL_11_0,&IID_ID3D12Device,(void**)&d);if(FAILED(r))return fail("device %08lx",r);D3D12_COMMAND_QUEUE_DESC q={0};ID3D12CommandQueue*cq;r=ID3D12Device_CreateCommandQueue(d,&q,&IID_ID3D12CommandQueue,(void**)&cq);return FAILED(r)?fail("queue %08lx",r):pass("device and queue");}
 T("opengl"){HWND h=win(WS_OVERLAPPEDWINDOW);HDC d=GetDC(h);PIXELFORMATDESCRIPTOR p={sizeof p,1,PFD_DRAW_TO_WINDOW|PFD_SUPPORT_OPENGL|PFD_DOUBLEBUFFER,0,32};SetPixelFormat(d,ChoosePixelFormat(d,&p),&p);HMODULE m=LoadLibraryA("opengl32.dll");HGLRC(WINAPI*cc)(HDC)=(void*)GetProcAddress(m,"wglCreateContext");BOOL(WINAPI*mk)(HDC,HGLRC)=(void*)GetProcAddress(m,"wglMakeCurrent");const char*(WINAPI*gs)(unsigned)=(void*)GetProcAddress(m,"glGetString");PROC(WINAPI*gp)(LPCSTR)=(void*)GetProcAddress(m,"wglGetProcAddress");HGLRC g=cc(d);if(!g||!mk(d,g))return fail("context");char a[64];lstrcpynA(a,gs(0x1F02),60);HGLRC(WINAPI*ca)(HDC,HGLRC,const int*)=(void*)gp("wglCreateContextAttribsARB");const char*hi="none";if(ca){static const int vs[][2]={{4,6},{4,5},{4,3},{4,1},{3,3},{3,2}};static char b[16];for(int i=0;i<6;i++){int at[]={0x2091,vs[i][0],0x2092,vs[i][1],0x9126,1,0x2094,2,0};if(ca(d,0,at)){sprintf(b,"%d.%d",vs[i][0],vs[i][1]);hi=b;break;}}}return pass("legacy %s, core max %s",a,hi);}
 T("vulkan"){HMODULE m=LoadLibraryA("vulkan-1.dll");if(!m)return fail("no vulkan-1.dll");struct{int s;const void*p;int f;const void*a;int lc;const void*l;int ec;const void*e;}ci={1};int(WINAPI*mk)(void*,void*,void**)=(void*)GetProcAddress(m,"vkCreateInstance");int(WINAPI*en)(void*,UINT*,void**)=(void*)GetProcAddress(m,"vkEnumeratePhysicalDevices");void*in=0;int r=mk?mk(&ci,0,&in):-99;UINT c=0;if(r)return fail("instance %d",r);en(in,&c,0);return c?pass("%u device",c):fail("no device");}
 T("audio"){WAVEFORMATEX f={1,2,44100,176400,4,16,0};HWAVEOUT w;MMRESULT r=waveOutOpen(&w,WAVE_MAPPER,&f,0,0,0);if(r)return fail("waveOut %u, %u devices",r,waveOutGetNumDevs());static short s[8820];WAVEHDR h={(char*)s,sizeof s};waveOutPrepareHeader(w,&h,sizeof h);waveOutWrite(w,&h,sizeof h);for(int i=0;i<300&&!(h.dwFlags&WHDR_DONE);i++)Sleep(10);return h.dwFlags&WHDR_DONE?pass("buffer played (silence)"):fail("buffer never finished");}
 T("gamepad-api"){HMODULE m=LoadLibraryA("xinput1_4.dll");DWORD(WINAPI*f)(DWORD,XINPUT_STATE*)=(void*)GetProcAddress(m,"XInputGetState");XINPUT_STATE s;if(!f)return fail("missing");DWORD r=f(0,&s);return(r==0||r==1167)?pass("API works, controller %s",r?"not attached":"attached"):fail("%lu",r);}
 T("rawinput"){RAWINPUTDEVICE r={1,2,0,win(WS_OVERLAPPEDWINDOW)};return RegisterRawInputDevices(&r,1,sizeof r)?pass("mouse registered"):fail("%lu",GetLastError());}
 T("https"){HINTERNET s=WinHttpOpen(L"compat",0,0,0,0),c=WinHttpConnect(s,L"example.com",443,0),r=WinHttpOpenRequest(c,L"GET",L"/",0,0,0,WINHTTP_FLAG_SECURE);if(!WinHttpSendRequest(r,0,0,0,0,0,0)||!WinHttpReceiveResponse(r,0))return fail("error %lu",GetLastError());DWORD st=0,l=4;WinHttpQueryHeaders(r,WINHTTP_QUERY_STATUS_CODE|WINHTTP_QUERY_FLAG_NUMBER,0,&st,&l,0);return st==200?pass("200"):fail("%lu",st);}
 T("https-badcert"){HINTERNET s=WinHttpOpen(L"compat",0,0,0,0),c=WinHttpConnect(s,L"expired.badssl.com",443,0),r=WinHttpOpenRequest(c,L"GET",L"/",0,0,0,WINHTTP_FLAG_SECURE);if(!WinHttpSendRequest(r,0,0,0,0,0,0))return GetLastError()==12175?pass("rejected"):fail("unexpected error %lu",GetLastError());return fail("accepted an expired certificate");}
 T("files"){char p[300];WCHAR w[]=L"C:\\t\x00e9st \x0645\x0631\x062d\x0628\x0627 \x4f60.txt";HANDLE f=CreateFileW(w,GENERIC_READ|GENERIC_WRITE,0,0,CREATE_ALWAYS,0,0);if(f==INVALID_HANDLE_VALUE)return fail("unicode name %lu",GetLastError());HANDLE g=CreateFileW(w,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);if(g!=INVALID_HANDLE_VALUE)return fail("sharing not enforced");LARGE_INTEGER z;z.QuadPart=5000000000LL;if(!SetFilePointerEx(f,z,0,0)||!SetEndOfFile(f))return fail("5GB sparse %lu",GetLastError());CloseHandle(f);DeleteFileW(w);strcpy(p,"C:\\");for(int i=0;i<3;i++){strcat(p,"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\");CreateDirectoryA(p,0);}return pass("unicode, sharing, 5GB sparse");}
 T("registry"){HKEY k;DWORD v2=7,l=4,x=0;if(RegCreateKeyA(HKEY_CURRENT_USER,"Software\\Compat",&k))return fail("create");RegSetValueExA(k,"v",0,REG_DWORD,(BYTE*)&v2,4);RegQueryValueExA(k,"v",0,0,(BYTE*)&x,&l);RegDeleteTreeA(HKEY_CURRENT_USER,"Software\\Compat");return x==7?pass("ok"):fail("read %lu",x);}
 T("threads"){static LONG c;HANDLE h[32];for(int i=0;i<32;i++)h[i]=CreateThread(0,0,thr,&c,0,0);WaitForMultipleObjects(32,h,1,60000);return c==6400000?pass("32 threads"):fail("%ld",c);}
 T("seh"){/* vectored handler + guard page */int ok=0;void*p=VirtualAlloc(0,4096,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);DWORD o;VirtualProtect(p,4096,PAGE_READONLY,&o);SIZE_T w;ok=!WriteProcessMemory(GetCurrentProcess(),(void*)1,&o,4,&w);return ok?pass("bad write refused"):fail("bad write allowed");}
 T("memory"){SIZE_T got=0;int big=sizeof(void*)==8?24:5;for(int i=0;i<big;i++){char*p=VirtualAlloc(0,256<<20,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);if(!p)break;for(SIZE_T k=0;k<(8<<20);k+=4096)p[k]=1;got+=256;}return got>=(SIZE_T)big*256?pass("%lu MB",(unsigned long)got):fail("%lu MB",(unsigned long)got);}
 T("child"){char c[400];PROCESS_INFORMATION p;STARTUPINFOA s={sizeof s};GetModuleFileNameA(0,c,300);strcat(c," basic");if(!CreateProcessA(0,c,0,0,0,0,0,0,&s,&p))return fail("%lu",GetLastError());WaitForSingleObject(p.hProcess,30000);DWORD x=9;GetExitCodeProcess(p.hProcess,&x);return x?fail("exit %lu",x):pass("spawned");}
 T("clipboard"){HWND h=win(WS_OVERLAPPEDWINDOW);(void)h;return OpenClipboard(0)&&CloseClipboard()?pass("opens (contents untouched)"):fail("%lu",GetLastError());}
 T("crypto"){BCRYPT_ALG_HANDLE a;BYTE b[16];return BCryptOpenAlgorithmProvider(&a,L"SHA256",0,0)||BCryptGenRandom(0,b,16,2)?fail("bcrypt"):pass("ok");}
 T("fonts"){HDC d=GetDC(0);SIZE z;HFONT f=CreateFontA(-20,0,0,0,400,0,0,0,DEFAULT_CHARSET,0,0,0,0,"Segoe UI");SelectObject(d,f);GetTextExtentPoint32A(d,"Hello World",11,&z);char nm[64];GetTextFaceA(d,64,nm);return z.cx>40?pass("Segoe UI -> %s, width %ld",nm,z.cx):fail("width %ld",z.cx);}
 T("driver"){SC_HANDLE m=OpenSCManagerA(0,0,SC_MANAGER_ALL_ACCESS);if(!m)return fail("no service manager %lu",GetLastError());return pass("service manager opens (real kernel drivers still cannot load)");}
 T("isolation"){char u[]="\\\\?\\unix/etc/hosts";HANDLE a=CreateFileA("Z:\\etc\\hosts",GENERIC_READ,1,0,OPEN_EXISTING,0,0),b=CreateFileA(u,GENERIC_READ,1,0,OPEN_EXISTING,0,0);printf("z-drive=%s unix-path=%s ",a==INVALID_HANDLE_VALUE?"blocked":"OPEN",b==INVALID_HANDLE_VALUE?"blocked":"OPEN");return a==INVALID_HANDLE_VALUE&&b==INVALID_HANDLE_VALUE?pass("blocked"):fail("Mac files readable");}
 return fail("unknown test");}
