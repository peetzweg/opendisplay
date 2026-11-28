/**
 *  Copyright (C) 2012  Juho Vähä-Herttua
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2.1 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License for more details.
 *
 *==================================================================
 * modified by fduncanh 2021-2022
 */

#ifndef GLOBAL_H
#define GLOBAL_H

#ifndef GLOBAL_MODEL
#define GLOBAL_MODEL    "AppleTV3,2"
#endif
#ifndef GLOBAL_VERSION
#define GLOBAL_VERSION  "220.68"
#endif

/* use old protocol for audio AES key if client's User-Agent string is contained in these strings */
/* replace xxx by any new User-Agent string as needed */
#define OLD_PROTOCOL_CLIENT_USER_AGENT_LIST "AirMyPC/2.0;xxx"

#define DECRYPTION_TEST 0    /* set to 1 or 2 to examine audio decryption */

#define MAX_HWADDR_LEN 6

#endif
