# tools/profile — профиль шага воздуха в игре (RW-15b)

Скрипты: `xc_prof.gd/.tscn` — копия `tests/atmosphere/xc/xc_run.gd` с таймерами вокруг вызовов фасада и
флагами `--size=N` (квадратное место N x N узлов, шаг 25 м, центр в начале), `--nondet` (как в игре: фоновые
задачи крейта не ждём), `--dyn` (живые термики/облака вместо статических), `--objs` (раз в игровую секунду
опросы потребителей: `cloud_objects(all)` + `CloudModel.parse`, `cores(6 км)`, `background_wind`).
`run.sh` — прогон; `threads.sh` — то же + CPU по потокам процесса (`/proc/<pid>/task/*/stat`, perf в среде
недоступен: `perf_event_paranoid=3`).

Воспроизведение (из корня копии; расширение: `tools/build_rust.sh tune linux`; один раз `godot --headless --path . --import`):

    tools/profile/run.sh c3041 --size=3041 --time-limit=3600
    tools/profile/run.sh nd3041 --size=3041 --time-limit=3600 --nondet
    tools/profile/threads.sh u3041 --size=3041 --time-limit=3600
    tools/profile/run.sh o3041 --size=3041 --time-limit=1200 --dyn --objs --nondet --clouds

Результаты — `results/` (json профиля, логи, CPU по потокам). Данные синтетические, лицензий нет.
