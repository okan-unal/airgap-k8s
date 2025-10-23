Bu klasördeki *.tar.part-* parçalarını offline node üzerinde birleştirip:
  cat <ad>.tar.part-* > /tmp/<ad>.tar
sonra:
  ctr -n k8s.io images import /tmp/<ad>.tar
ile içeri alın. (amd64 arşivdir)
