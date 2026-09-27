"""Промпты для генерации кандидатов (EN — модели обучены на английских описаниях).
key → (prompt, negative_prompt, длина_с)."""
NEG = "music, melody, speech, voice, talking, engine, motor, car, traffic, low quality, distorted"
PROMPTS = {
    "airflow_30": ("gentle steady wind rushing past the ears while gliding through the air at moderate speed, soft airflow whoosh, field recording", NEG, 20),
    "airflow_50": ("strong steady wind rushing past the microphone while flying through the air, continuous whooshing airflow noise, field recording", NEG, 20),
    "airflow_80": ("very loud roaring wind buffeting a helmet at high speed, intense rushing airflow, continuous, field recording", NEG, 20),
    "sail_rustle": ("nylon fabric wing rustling and fluttering softly in the wind, close up", NEG, 20),
    "sail_flap": ("large nylon sail flapping and snapping loudly in strong wind", NEG, 20),
    "trailing_edge": ("fabric edge fluttering rapidly in strong wind, fast flag flutter buzz", NEG, 20),
    "frame_creak": ("aluminium tube frame and ropes creaking under load, slow creaks", NEG, 10),
    "meadow_wind_grass": ("wind blowing through tall grass on a mountain meadow, gentle gusts, nature ambience", NEG, 30),
    "meadow_birds": ("birds singing on an alpine meadow on a summer morning, peaceful nature ambience", NEG, 30),
    "cowbells": ("distant cowbells of a herd grazing on an alpine pasture, light wind, nature ambience", NEG, 30),
}
