from google.protobuf.internal import containers as _containers
from google.protobuf.internal import enum_type_wrapper as _enum_type_wrapper
from google.protobuf import descriptor as _descriptor
from google.protobuf import message as _message
from collections.abc import Iterable as _Iterable, Mapping as _Mapping
from typing import ClassVar as _ClassVar, Optional as _Optional, Union as _Union

DESCRIPTOR: _descriptor.FileDescriptor

class HeightGrid(_message.Message):
    __slots__ = ("nx", "ny", "dx_m", "x0_m", "y0_m", "offset_m", "scale_m", "h_i16")
    NX_FIELD_NUMBER: _ClassVar[int]
    NY_FIELD_NUMBER: _ClassVar[int]
    DX_M_FIELD_NUMBER: _ClassVar[int]
    X0_M_FIELD_NUMBER: _ClassVar[int]
    Y0_M_FIELD_NUMBER: _ClassVar[int]
    OFFSET_M_FIELD_NUMBER: _ClassVar[int]
    SCALE_M_FIELD_NUMBER: _ClassVar[int]
    H_I16_FIELD_NUMBER: _ClassVar[int]
    nx: int
    ny: int
    dx_m: float
    x0_m: float
    y0_m: float
    offset_m: float
    scale_m: float
    h_i16: bytes
    def __init__(self, nx: _Optional[int] = ..., ny: _Optional[int] = ..., dx_m: _Optional[float] = ..., x0_m: _Optional[float] = ..., y0_m: _Optional[float] = ..., offset_m: _Optional[float] = ..., scale_m: _Optional[float] = ..., h_i16: _Optional[bytes] = ...) -> None: ...

class Form(_message.Message):
    __slots__ = ("kind", "x_m", "y_m", "theta_rad", "height", "sigma_m", "sigma2_m", "length_m", "edge", "asym")
    class Kind(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
        __slots__ = ()
        KIND_UNSPECIFIED: _ClassVar[Form.Kind]
        RIDGE: _ClassVar[Form.Kind]
        BLOB: _ClassVar[Form.Kind]
        STEP: _ClassVar[Form.Kind]
    KIND_UNSPECIFIED: Form.Kind
    RIDGE: Form.Kind
    BLOB: Form.Kind
    STEP: Form.Kind
    KIND_FIELD_NUMBER: _ClassVar[int]
    X_M_FIELD_NUMBER: _ClassVar[int]
    Y_M_FIELD_NUMBER: _ClassVar[int]
    THETA_RAD_FIELD_NUMBER: _ClassVar[int]
    HEIGHT_FIELD_NUMBER: _ClassVar[int]
    SIGMA_M_FIELD_NUMBER: _ClassVar[int]
    SIGMA2_M_FIELD_NUMBER: _ClassVar[int]
    LENGTH_M_FIELD_NUMBER: _ClassVar[int]
    EDGE_FIELD_NUMBER: _ClassVar[int]
    ASYM_FIELD_NUMBER: _ClassVar[int]
    kind: Form.Kind
    x_m: float
    y_m: float
    theta_rad: float
    height: float
    sigma_m: float
    sigma2_m: float
    length_m: float
    edge: float
    asym: float
    def __init__(self, kind: _Optional[_Union[Form.Kind, str]] = ..., x_m: _Optional[float] = ..., y_m: _Optional[float] = ..., theta_rad: _Optional[float] = ..., height: _Optional[float] = ..., sigma_m: _Optional[float] = ..., sigma2_m: _Optional[float] = ..., length_m: _Optional[float] = ..., edge: _Optional[float] = ..., asym: _Optional[float] = ...) -> None: ...

class GenParams(_message.Message):
    __slots__ = ("mix", "n_compute", "dx_compute_m", "uplift_max_m_per_yr", "uplift_floor", "fourier_amp", "fourier_beta", "anisotropy", "strike_rad", "forms", "k0", "k_logsd", "k_beta", "m_exp", "n_exp", "diffusion_m2_per_yr", "tan_crit", "thermal_passes", "t_total_yr", "dt_yr", "noise_m", "base_elevation_m", "extra")
    class ExtraEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: float
        def __init__(self, key: _Optional[str] = ..., value: _Optional[float] = ...) -> None: ...
    MIX_FIELD_NUMBER: _ClassVar[int]
    N_COMPUTE_FIELD_NUMBER: _ClassVar[int]
    DX_COMPUTE_M_FIELD_NUMBER: _ClassVar[int]
    UPLIFT_MAX_M_PER_YR_FIELD_NUMBER: _ClassVar[int]
    UPLIFT_FLOOR_FIELD_NUMBER: _ClassVar[int]
    FOURIER_AMP_FIELD_NUMBER: _ClassVar[int]
    FOURIER_BETA_FIELD_NUMBER: _ClassVar[int]
    ANISOTROPY_FIELD_NUMBER: _ClassVar[int]
    STRIKE_RAD_FIELD_NUMBER: _ClassVar[int]
    FORMS_FIELD_NUMBER: _ClassVar[int]
    K0_FIELD_NUMBER: _ClassVar[int]
    K_LOGSD_FIELD_NUMBER: _ClassVar[int]
    K_BETA_FIELD_NUMBER: _ClassVar[int]
    M_EXP_FIELD_NUMBER: _ClassVar[int]
    N_EXP_FIELD_NUMBER: _ClassVar[int]
    DIFFUSION_M2_PER_YR_FIELD_NUMBER: _ClassVar[int]
    TAN_CRIT_FIELD_NUMBER: _ClassVar[int]
    THERMAL_PASSES_FIELD_NUMBER: _ClassVar[int]
    T_TOTAL_YR_FIELD_NUMBER: _ClassVar[int]
    DT_YR_FIELD_NUMBER: _ClassVar[int]
    NOISE_M_FIELD_NUMBER: _ClassVar[int]
    BASE_ELEVATION_M_FIELD_NUMBER: _ClassVar[int]
    EXTRA_FIELD_NUMBER: _ClassVar[int]
    mix: float
    n_compute: int
    dx_compute_m: float
    uplift_max_m_per_yr: float
    uplift_floor: float
    fourier_amp: float
    fourier_beta: float
    anisotropy: float
    strike_rad: float
    forms: _containers.RepeatedCompositeFieldContainer[Form]
    k0: float
    k_logsd: float
    k_beta: float
    m_exp: float
    n_exp: float
    diffusion_m2_per_yr: float
    tan_crit: float
    thermal_passes: int
    t_total_yr: float
    dt_yr: float
    noise_m: float
    base_elevation_m: float
    extra: _containers.ScalarMap[str, float]
    def __init__(self, mix: _Optional[float] = ..., n_compute: _Optional[int] = ..., dx_compute_m: _Optional[float] = ..., uplift_max_m_per_yr: _Optional[float] = ..., uplift_floor: _Optional[float] = ..., fourier_amp: _Optional[float] = ..., fourier_beta: _Optional[float] = ..., anisotropy: _Optional[float] = ..., strike_rad: _Optional[float] = ..., forms: _Optional[_Iterable[_Union[Form, _Mapping]]] = ..., k0: _Optional[float] = ..., k_logsd: _Optional[float] = ..., k_beta: _Optional[float] = ..., m_exp: _Optional[float] = ..., n_exp: _Optional[float] = ..., diffusion_m2_per_yr: _Optional[float] = ..., tan_crit: _Optional[float] = ..., thermal_passes: _Optional[int] = ..., t_total_yr: _Optional[float] = ..., dt_yr: _Optional[float] = ..., noise_m: _Optional[float] = ..., base_elevation_m: _Optional[float] = ..., extra: _Optional[_Mapping[str, float]] = ...) -> None: ...

class ReliefSummary(_message.Message):
    __slots__ = ("h_min_m", "h_max_m", "relief_m", "slope_mean_deg_400", "slope_p95_deg_100", "compute_seconds")
    H_MIN_M_FIELD_NUMBER: _ClassVar[int]
    H_MAX_M_FIELD_NUMBER: _ClassVar[int]
    RELIEF_M_FIELD_NUMBER: _ClassVar[int]
    SLOPE_MEAN_DEG_400_FIELD_NUMBER: _ClassVar[int]
    SLOPE_P95_DEG_100_FIELD_NUMBER: _ClassVar[int]
    COMPUTE_SECONDS_FIELD_NUMBER: _ClassVar[int]
    h_min_m: float
    h_max_m: float
    relief_m: float
    slope_mean_deg_400: float
    slope_p95_deg_100: float
    compute_seconds: float
    def __init__(self, h_min_m: _Optional[float] = ..., h_max_m: _Optional[float] = ..., relief_m: _Optional[float] = ..., slope_mean_deg_400: _Optional[float] = ..., slope_p95_deg_100: _Optional[float] = ..., compute_seconds: _Optional[float] = ...) -> None: ...

class Relief(_message.Message):
    __slots__ = ("id", "corpus_seed", "generator_version", "params", "g100", "g400", "summary", "place")
    ID_FIELD_NUMBER: _ClassVar[int]
    CORPUS_SEED_FIELD_NUMBER: _ClassVar[int]
    GENERATOR_VERSION_FIELD_NUMBER: _ClassVar[int]
    PARAMS_FIELD_NUMBER: _ClassVar[int]
    G100_FIELD_NUMBER: _ClassVar[int]
    G400_FIELD_NUMBER: _ClassVar[int]
    SUMMARY_FIELD_NUMBER: _ClassVar[int]
    PLACE_FIELD_NUMBER: _ClassVar[int]
    id: int
    corpus_seed: int
    generator_version: str
    params: GenParams
    g100: HeightGrid
    g400: HeightGrid
    summary: ReliefSummary
    place: Place
    def __init__(self, id: _Optional[int] = ..., corpus_seed: _Optional[int] = ..., generator_version: _Optional[str] = ..., params: _Optional[_Union[GenParams, _Mapping]] = ..., g100: _Optional[_Union[HeightGrid, _Mapping]] = ..., g400: _Optional[_Union[HeightGrid, _Mapping]] = ..., summary: _Optional[_Union[ReliefSummary, _Mapping]] = ..., place: _Optional[_Union[Place, _Mapping]] = ...) -> None: ...

class Place(_message.Message):
    __slots__ = ("name", "lat_deg", "lon_deg", "system", "part", "stratum", "source", "zoom", "src_spacing_m", "source_sha256", "extra")
    class ExtraEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    NAME_FIELD_NUMBER: _ClassVar[int]
    LAT_DEG_FIELD_NUMBER: _ClassVar[int]
    LON_DEG_FIELD_NUMBER: _ClassVar[int]
    SYSTEM_FIELD_NUMBER: _ClassVar[int]
    PART_FIELD_NUMBER: _ClassVar[int]
    STRATUM_FIELD_NUMBER: _ClassVar[int]
    SOURCE_FIELD_NUMBER: _ClassVar[int]
    ZOOM_FIELD_NUMBER: _ClassVar[int]
    SRC_SPACING_M_FIELD_NUMBER: _ClassVar[int]
    SOURCE_SHA256_FIELD_NUMBER: _ClassVar[int]
    EXTRA_FIELD_NUMBER: _ClassVar[int]
    name: str
    lat_deg: float
    lon_deg: float
    system: str
    part: str
    stratum: str
    source: str
    zoom: int
    src_spacing_m: float
    source_sha256: str
    extra: _containers.ScalarMap[str, str]
    def __init__(self, name: _Optional[str] = ..., lat_deg: _Optional[float] = ..., lon_deg: _Optional[float] = ..., system: _Optional[str] = ..., part: _Optional[str] = ..., stratum: _Optional[str] = ..., source: _Optional[str] = ..., zoom: _Optional[int] = ..., src_spacing_m: _Optional[float] = ..., source_sha256: _Optional[str] = ..., extra: _Optional[_Mapping[str, str]] = ...) -> None: ...

class IndexEntry(_message.Message):
    __slots__ = ("id", "shard", "offset", "length", "cond_id", "mix", "relief_m")
    ID_FIELD_NUMBER: _ClassVar[int]
    SHARD_FIELD_NUMBER: _ClassVar[int]
    OFFSET_FIELD_NUMBER: _ClassVar[int]
    LENGTH_FIELD_NUMBER: _ClassVar[int]
    COND_ID_FIELD_NUMBER: _ClassVar[int]
    MIX_FIELD_NUMBER: _ClassVar[int]
    RELIEF_M_FIELD_NUMBER: _ClassVar[int]
    id: int
    shard: int
    offset: int
    length: int
    cond_id: int
    mix: float
    relief_m: float
    def __init__(self, id: _Optional[int] = ..., shard: _Optional[int] = ..., offset: _Optional[int] = ..., length: _Optional[int] = ..., cond_id: _Optional[int] = ..., mix: _Optional[float] = ..., relief_m: _Optional[float] = ...) -> None: ...

class ShardIndex(_message.Message):
    __slots__ = ("kind", "entries")
    KIND_FIELD_NUMBER: _ClassVar[int]
    ENTRIES_FIELD_NUMBER: _ClassVar[int]
    kind: str
    entries: _containers.RepeatedCompositeFieldContainer[IndexEntry]
    def __init__(self, kind: _Optional[str] = ..., entries: _Optional[_Iterable[_Union[IndexEntry, _Mapping]]] = ...) -> None: ...

class CorpusManifest(_message.Message):
    __slots__ = ("contract", "name", "kind", "generator_version", "corpus_seed", "n_records", "shard_size", "shard_pattern", "complete", "command", "git_commit", "created", "relief_corpus", "notes")
    class NotesEntry(_message.Message):
        __slots__ = ("key", "value")
        KEY_FIELD_NUMBER: _ClassVar[int]
        VALUE_FIELD_NUMBER: _ClassVar[int]
        key: str
        value: str
        def __init__(self, key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...
    CONTRACT_FIELD_NUMBER: _ClassVar[int]
    NAME_FIELD_NUMBER: _ClassVar[int]
    KIND_FIELD_NUMBER: _ClassVar[int]
    GENERATOR_VERSION_FIELD_NUMBER: _ClassVar[int]
    CORPUS_SEED_FIELD_NUMBER: _ClassVar[int]
    N_RECORDS_FIELD_NUMBER: _ClassVar[int]
    SHARD_SIZE_FIELD_NUMBER: _ClassVar[int]
    SHARD_PATTERN_FIELD_NUMBER: _ClassVar[int]
    COMPLETE_FIELD_NUMBER: _ClassVar[int]
    COMMAND_FIELD_NUMBER: _ClassVar[int]
    GIT_COMMIT_FIELD_NUMBER: _ClassVar[int]
    CREATED_FIELD_NUMBER: _ClassVar[int]
    RELIEF_CORPUS_FIELD_NUMBER: _ClassVar[int]
    NOTES_FIELD_NUMBER: _ClassVar[int]
    contract: str
    name: str
    kind: str
    generator_version: str
    corpus_seed: int
    n_records: int
    shard_size: int
    shard_pattern: str
    complete: bool
    command: str
    git_commit: str
    created: str
    relief_corpus: str
    notes: _containers.ScalarMap[str, str]
    def __init__(self, contract: _Optional[str] = ..., name: _Optional[str] = ..., kind: _Optional[str] = ..., generator_version: _Optional[str] = ..., corpus_seed: _Optional[int] = ..., n_records: _Optional[int] = ..., shard_size: _Optional[int] = ..., shard_pattern: _Optional[str] = ..., complete: _Optional[bool] = ..., command: _Optional[str] = ..., git_commit: _Optional[str] = ..., created: _Optional[str] = ..., relief_corpus: _Optional[str] = ..., notes: _Optional[_Mapping[str, str]] = ...) -> None: ...

class Conditions(_message.Message):
    __slots__ = ("relief_id", "cond_id", "cond_seed", "u10_m_s", "wind_from_deg", "hour_local", "sky", "t_max_c", "month", "day", "lat_deg", "lon_deg", "utc_offset_h", "derived", "strat_override")
    RELIEF_ID_FIELD_NUMBER: _ClassVar[int]
    COND_ID_FIELD_NUMBER: _ClassVar[int]
    COND_SEED_FIELD_NUMBER: _ClassVar[int]
    U10_M_S_FIELD_NUMBER: _ClassVar[int]
    WIND_FROM_DEG_FIELD_NUMBER: _ClassVar[int]
    HOUR_LOCAL_FIELD_NUMBER: _ClassVar[int]
    SKY_FIELD_NUMBER: _ClassVar[int]
    T_MAX_C_FIELD_NUMBER: _ClassVar[int]
    MONTH_FIELD_NUMBER: _ClassVar[int]
    DAY_FIELD_NUMBER: _ClassVar[int]
    LAT_DEG_FIELD_NUMBER: _ClassVar[int]
    LON_DEG_FIELD_NUMBER: _ClassVar[int]
    UTC_OFFSET_H_FIELD_NUMBER: _ClassVar[int]
    DERIVED_FIELD_NUMBER: _ClassVar[int]
    STRAT_OVERRIDE_FIELD_NUMBER: _ClassVar[int]
    relief_id: int
    cond_id: int
    cond_seed: int
    u10_m_s: float
    wind_from_deg: float
    hour_local: float
    sky: str
    t_max_c: float
    month: int
    day: int
    lat_deg: float
    lon_deg: float
    utc_offset_h: float
    derived: Derived
    strat_override: StratOverride
    def __init__(self, relief_id: _Optional[int] = ..., cond_id: _Optional[int] = ..., cond_seed: _Optional[int] = ..., u10_m_s: _Optional[float] = ..., wind_from_deg: _Optional[float] = ..., hour_local: _Optional[float] = ..., sky: _Optional[str] = ..., t_max_c: _Optional[float] = ..., month: _Optional[int] = ..., day: _Optional[int] = ..., lat_deg: _Optional[float] = ..., lon_deg: _Optional[float] = ..., utc_offset_h: _Optional[float] = ..., derived: _Optional[_Union[Derived, _Mapping]] = ..., strat_override: _Optional[_Union[StratOverride, _Mapping]] = ...) -> None: ...

class Derived(_message.Message):
    __slots__ = ("alpha", "max_profile", "z_i_m", "z_lcl_m", "heat", "brk", "stability_class", "has_cap", "cap_agl_m", "sun_el_deg", "sun_az_deg", "t_c", "n_bv_s", "froude", "w_star_m_s", "w_star_over_u", "mechanical")
    ALPHA_FIELD_NUMBER: _ClassVar[int]
    MAX_PROFILE_FIELD_NUMBER: _ClassVar[int]
    Z_I_M_FIELD_NUMBER: _ClassVar[int]
    Z_LCL_M_FIELD_NUMBER: _ClassVar[int]
    HEAT_FIELD_NUMBER: _ClassVar[int]
    BRK_FIELD_NUMBER: _ClassVar[int]
    STABILITY_CLASS_FIELD_NUMBER: _ClassVar[int]
    HAS_CAP_FIELD_NUMBER: _ClassVar[int]
    CAP_AGL_M_FIELD_NUMBER: _ClassVar[int]
    SUN_EL_DEG_FIELD_NUMBER: _ClassVar[int]
    SUN_AZ_DEG_FIELD_NUMBER: _ClassVar[int]
    T_C_FIELD_NUMBER: _ClassVar[int]
    N_BV_S_FIELD_NUMBER: _ClassVar[int]
    FROUDE_FIELD_NUMBER: _ClassVar[int]
    W_STAR_M_S_FIELD_NUMBER: _ClassVar[int]
    W_STAR_OVER_U_FIELD_NUMBER: _ClassVar[int]
    MECHANICAL_FIELD_NUMBER: _ClassVar[int]
    alpha: float
    max_profile: float
    z_i_m: float
    z_lcl_m: float
    heat: float
    brk: float
    stability_class: int
    has_cap: bool
    cap_agl_m: float
    sun_el_deg: float
    sun_az_deg: float
    t_c: float
    n_bv_s: float
    froude: float
    w_star_m_s: float
    w_star_over_u: float
    mechanical: bool
    def __init__(self, alpha: _Optional[float] = ..., max_profile: _Optional[float] = ..., z_i_m: _Optional[float] = ..., z_lcl_m: _Optional[float] = ..., heat: _Optional[float] = ..., brk: _Optional[float] = ..., stability_class: _Optional[int] = ..., has_cap: _Optional[bool] = ..., cap_agl_m: _Optional[float] = ..., sun_el_deg: _Optional[float] = ..., sun_az_deg: _Optional[float] = ..., t_c: _Optional[float] = ..., n_bv_s: _Optional[float] = ..., froude: _Optional[float] = ..., w_star_m_s: _Optional[float] = ..., w_star_over_u: _Optional[float] = ..., mechanical: _Optional[bool] = ...) -> None: ...

class StratOverride(_message.Message):
    __slots__ = ("enabled", "n_bv_s", "z_i_agl_m", "theta_profile_k", "theta_z_m")
    ENABLED_FIELD_NUMBER: _ClassVar[int]
    N_BV_S_FIELD_NUMBER: _ClassVar[int]
    Z_I_AGL_M_FIELD_NUMBER: _ClassVar[int]
    THETA_PROFILE_K_FIELD_NUMBER: _ClassVar[int]
    THETA_Z_M_FIELD_NUMBER: _ClassVar[int]
    enabled: bool
    n_bv_s: float
    z_i_agl_m: float
    theta_profile_k: _containers.RepeatedScalarFieldContainer[float]
    theta_z_m: _containers.RepeatedScalarFieldContainer[float]
    def __init__(self, enabled: _Optional[bool] = ..., n_bv_s: _Optional[float] = ..., z_i_agl_m: _Optional[float] = ..., theta_profile_k: _Optional[_Iterable[float]] = ..., theta_z_m: _Optional[_Iterable[float]] = ...) -> None: ...
