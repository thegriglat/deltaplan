import os

# на загруженной машине многопоточный BLAS на малых матрицах медленнее в десятки раз
for _k in ("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_k, "1")
