import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn smoke_test() {
  1 + 1 |> should.equal(2)
}
