// Upstream worse_query declarations, GPL-3.0-or-later.
// Copyright (C) 2026 Taj C (forcequit). See THIRD_PARTY.md.
#ifndef WORSE_QUERY_H
#define WORSE_QUERY_H

#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdbool.h>

int64_t worse_query(NSString *path, NSString *group, bool alt_flags, bool create_dir);
void worse_query_release(int64_t handle);

#endif
