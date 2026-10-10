/* Формат generic пакета движения Deltaplan (MR-К2 v1): один UDP-датаграм = одна структура, 64 байта.
 * ВСЕ ЧИСЛА LITTLE-ENDIAN (x86, ARM Cortex-M, ESP32 — нативно; на big-endian переставлять байты).
 * Без зависимостей, выравнивания нет (все поля по 4 байта, packed). Величины — «честные», без фильтров;
 * знаки при необходимости инвертирует игрок в настройках игры (signs). Оси пилота: вперёд, вправо, вверх. */
#ifndef DELTAPLAN_MOTION_GENERIC_H
#define DELTAPLAN_MOTION_GENERIC_H

#include <stddef.h>
#include <stdint.h>

#define DPMR_MAGIC "DPMR"
#define DPMR_VERSION 1u
#define DPMR_FLAG_VALID 1u     /* бит 0: величины валидны (есть прошлое состояние) */
#define DPMR_FLAG_ON_GROUND 2u /* бит 1: пилот на земле */

#pragma pack(push, 1)
typedef struct {
    char     magic[4];      /*  0: "DPMR" (без нуля) */
    uint32_t version;       /*  4: 1 */
    uint32_t seq;           /*  8: номер пакета с запуска отправки, +1 на пакет */
    uint32_t flags;         /* 12: DPMR_FLAG_* */
    float    t;             /* 16: с, время полёта */
    float    surge;         /* 20: м/с², удельная сила вперёд (нос > 0); горизонтальный полёт: g*sin(тангаж) */
    float    sway;          /* 24: м/с², удельная сила вправо (> 0) */
    float    heave;         /* 28: м/с², удельная сила вверх (> 0, «давит в сиденье»); горизонтальный полёт ≈ +9.81 */
    float    roll;          /* 32: град, крен: правое крыло вниз > 0, (-180, 180] */
    float    pitch;         /* 36: град, тангаж: нос вверх > 0, [-90, 90] */
    float    yaw;           /* 40: град, курс: 0 — север, по часовой (восток = 90), [0, 360) */
    float    roll_rate;     /* 44: град/с, вокруг оси вперёд: правое крыло вниз > 0 */
    float    pitch_rate;    /* 48: град/с, вокруг оси вправо: нос вверх > 0 */
    float    yaw_rate;      /* 52: град/с, вокруг оси вверх: нос вправо > 0 */
    float    airspeed;      /* 56: м/с, воздушная скорость */
    float    air_lateral;   /* 60: м/с, скольжение вправо > 0 */
} dpmr_packet_t;
#pragma pack(pop)

_Static_assert(sizeof(dpmr_packet_t) == 64, "generic packet must be 64 bytes");
_Static_assert(offsetof(dpmr_packet_t, air_lateral) == 60, "air_lateral offset");

#endif
