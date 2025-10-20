Bu klasördeki *.tar.part-* parçaları offline tarafta birleştirip:
  cat <ad>.tar.part-* > /tmp/<ad>.tar
ve sonra:
  ctr -n k8s.io images import /tmp/<ad>.tar
ile içeri alın. (amd64 arşivdir)
