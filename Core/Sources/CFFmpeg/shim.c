//
//  shim.c — deliberately empty.
//
//  Purpose : SwiftPM needs at least one compilable source file to treat CFFmpeg as a
//            C target and generate its module map from include/. All the content is
//            in the header; this file exists only to make the target valid.
//

#include "include/CFFmpeg.h"
