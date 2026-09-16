//
//  CFFmpeg.h — the C shim that exposes libav to Swift.
//
//  Purpose : Swift cannot import a bare collection of C headers, so this one header
//            pulls in exactly the libav surface Videoboy uses and SwiftPM turns it
//            into the `CFFmpeg` module.
//  Inputs  : the vendored LGPL FFmpeg headers under vendor/ffmpeg/include, which
//            scripts/_common.sh puts on the include path.
//  Outputs : the `CFFmpeg` Swift module.
//  Connects: DVDecoder and DVDemuxer in Core/Bitstream/.
//  Extend  : add an #include here when a new libav header is needed. Nothing else
//            in the project may include libav headers directly.
//

#ifndef VIDEOBOY_CFFMPEG_H
#define VIDEOBOY_CFFMPEG_H

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>

#endif /* VIDEOBOY_CFFMPEG_H */
